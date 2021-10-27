!**********************************************************************************************************************************
! LICENSING
! Copyright (C) 2020-2021 Alliance for Sustainable Energy, LLC
! Copyright (C) 2015-2019 Matthew Hall
!
!    This file is part of MoorDyn.
!
! Licensed under the Apache License, Version 2.0 (the "License");
! you may not use this file except in compliance with the License.
! You may obtain a copy of the License at
!
!     http://www.apache.org/licenses/LICENSE-2.0
!
! Unless required by applicable law or agreed to in writing, software
! distributed under the License is distributed on an "AS IS" BASIS,
! WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
! See the License for the specific language governing permissions and
! limitations under the License.
!
!**********************************************************************************************************************************
MODULE MoorDyn_Rod

   USE MoorDyn_Types
   USE MoorDyn_IO
   USE NWTC_Library
   USE MoorDyn_Misc
   USE MoorDyn_Line,           only : Line_SetEndKinematics, Line_GetEndStuff, Line_SetEndOrientation, Line_GetEndSegmentInfo
   
   IMPLICIT NONE

   PRIVATE

   INTEGER(IntKi), PARAMETER            :: wordy = 0   ! verbosity level. >1 = more console output

   PUBLIC :: Rod_Setup
   PUBLIC :: Rod_Initialize
   PUBLIC :: Rod_SetKinematics
   PUBLIC :: Rod_SetState
   PUBLIC :: Rod_GetStateDeriv
   PUBLIC :: Rod_DoRHS
   PUBLIC :: Rod_GetCoupledForce
   PUBLIC :: Rod_GetNetForceAndMass
   PUBLIC :: Rod_AddLine
   PUBLIC :: Rod_RemoveLine
   
   

CONTAINS


   !-----------------------------------------------------------------------
   SUBROUTINE Rod_Setup(Rod, RodProp, endCoords, rhoW, ErrStat, ErrMsg)

      TYPE(MD_Rod),       INTENT(INOUT)  :: Rod          ! the single rod object of interest
      TYPE(MD_RodProp),   INTENT(INOUT)  :: RodProp      ! the single rod property set for the line of interest
      REAL(DbKi),    INTENT(IN)          :: endCoords(6)
      REAL(DbKi),    INTENT(IN)          :: rhoW
      INTEGER,       INTENT(   INOUT )   :: ErrStat       ! returns a non-zero value when an error occurs
      CHARACTER(*),  INTENT(   INOUT )   :: ErrMsg        ! Error message if ErrStat /= ErrID_None

      INTEGER(4)                         :: i             ! Generic index
      INTEGER(4)                         :: K             ! Generic index
      INTEGER(IntKi)                     :: N

      N = Rod%N  ! number of segments in this line (for code readability)

      ! -------------- save some section properties to the line object itself -----------------

      Rod%d   = RodProp%d
      Rod%rho = RodProp%w/(Pi/4.0 * Rod%d * Rod%d)
      
      Rod%Can   = RodProp%Can
      Rod%Cat   = RodProp%Cat
      Rod%Cdn   = RodProp%Cdn
      Rod%Cdt   = RodProp%Cdt      
      Rod%CaEnd = RodProp%CaEnd      
      Rod%CdEnd = RodProp%CdEnd      
      

      ! allocate node positions and velocities (NOTE: these arrays start at ZERO)
      ALLOCATE ( Rod%r(3, 0:N), Rod%rd(3, 0:N), STAT = ErrStat )   ! <<<<<< add error checks here
      IF ( ErrStat /= ErrID_None ) print *, "Alloc error 1 in MoorDyn" 
     
      ! allocate segment scalar quantities
      if (Rod%N == 0) then                                ! special case of zero-length Rod
         ALLOCATE ( Rod%l(1), Rod%V(N), STAT = ErrStat )
      else                                                ! normal case
         ALLOCATE ( Rod%l(N), Rod%V(N), STAT = ErrStat )
      end if
      IF ( ErrStat /= ErrID_None ) print *, "Alloc error 2 in MoorDyn"

      ! allocate water related vectors
      ALLOCATE ( Rod%U(3, 0:N), Rod%Ud(3, 0:N), Rod%zeta(0:N), Rod%PDyn(0:N), STAT = ErrStat )
      IF ( ErrStat /= ErrID_None ) print *, "Alloc error 3 in MoorDyn"
      ! set to zero initially (important of wave kinematics are not being used)
      Rod%U    = 0.0_DbKi
      Rod%Ud   = 0.0_DbKi
      Rod%zeta = 0.0_DbKi
      Rod%PDyn = 0.0_DbKi

      ! allocate node force vectors
      ALLOCATE ( Rod%W(3, 0:N), Rod%Bo(3, 0:N), Rod%Dp(3, 0:N), Rod%Dq(3, 0:N), Rod%Ap(3, 0:N), &
         Rod%Aq(3, 0:N), Rod%Pd(3, 0:N), Rod%B(3, 0:N), Rod%Fnet(3, 0:N), STAT = ErrStat )
      IF ( ErrStat /= ErrID_None ) print *, "Alloc error 4 in MoorDyn"
      
      ! allocate mass and inverse mass matrices for each node (including ends)
      ALLOCATE ( Rod%M(3, 3, 0:N), STAT = ErrStat )
      IF ( ErrStat /= ErrID_None ) print *, "Alloc error 5 in MoorDyn"



      ! ------------------------- set some geometric properties and the starting kinematics -------------------------

      CALL UnitVector(endCoords(1:3), endCoords(4:6), Rod%q, Rod%UnstrLen)  ! get Rod axis direction vector and Rod length

      ! set Rod positions if applicable
      if (Rod%typeNum==0) then               ! for an independent rod, set the position right off the bat

         Rod%r6(1:3) = endCoords(1:3)      ! (end A coordinates) 
         Rod%v6(1:3) = 0.0_DbKi            ! (end A velocity, unrotated axes) 
   
         Rod%r6(4:6) = Rod%q               ! (Rod direction unit vector)
         Rod%v6(4:6) = 0.0_DbKi            ! (rotational velocities about unrotated axes) 

      else if (abs(Rod%typeNum)==1) then    ! for a pinned rod, just set the orientation (position will be set later by parent object)

         Rod%r6(4:6) = Rod%q               ! (Rod direction unit vector)
         Rod%v6(4:6) = 0.0_DbKi            ! (rotational velocities about unrotated axes) 

      end if
      ! otherwise (for a fixed rod) the positions will be set by the parent body or via coupling


      ! save mass for future calculations >>>> should calculate I_l and I_r here in future <<<<
      Rod%mass  = Rod%UnstrLen*RodProp%w


      ! assign values for l and V
      if (Rod%N == 0) then
         Rod%l(1) = 0.0_DbKi
         Rod%V(1) = 0.0_DbKi
      else
         DO i=1,N
            Rod%l(i) = Rod%UnstrLen/REAL(N, DbKi)
            Rod%V(i) = Rod%l(i)*0.25*Pi*RodProp%d*RodProp%d
         END DO
      end if
      

      ! set gravity and bottom contact forces to zero initially (because the horizontal components should remain at zero)
      Rod%W = 0.0_DbKi
      Rod%B = 0.0_DbKi
            
      IF (wordy > 0) print *, "Set up Rod ",Rod%IdNum, ", type ", Rod%typeNum

      ! need to add cleanup sub <<<

   END SUBROUTINE Rod_Setup
   !--------------------------------------------------------------




   ! Make output file for Rod and set end kinematics of any attached lines.
   ! For free Rods, fill in the initial states into the state vector.
   ! Notes: r6 and v6 must already be set.  
   !        ground- or body-pinned rods have already had setKinematics called to set first 3 elements of r6, v6.
   !--------------------------------------------------------------
   SUBROUTINE Rod_Initialize(Rod, states, m)

      TYPE(MD_Rod),          INTENT(INOUT)  :: Rod          ! the rod object 
      Real(DbKi),            INTENT(INOUT)  :: states(:)    ! state vector section for this line
      TYPE(MD_MiscVarType),  INTENT(INOUT)  :: m          ! passing along all mooring objects
      

      INTEGER(IntKi)                        :: l           ! index of segments or nodes along line
      REAL(DbKi)                            :: rRef(3)     ! reference position of mesh node
      REAL(DbKi)                            :: OrMat(3,3)  ! DCM for body orientation based on r6_in
   
      IF (wordy > 0) print *, "initializing Rod ", Rod%idNum

      ! the r6 and v6 vectors should have already been set
      ! r and rd of ends have already been set by setup function or by parent object   <<<<< right? <<<<<


      ! Pass kinematics to any attached lines (this is just like what a Connection does, except for both ends)
      ! so that they have the correct initial positions at this initialization stage.
      
      if (Rod%typeNum >- 2)  CALL Rod_SetDependentKin(Rod, 0.0_DbKi, m)  ! don't call this for type -2 coupled Rods as it's already been called


      ! assign the resulting kinematics to its part of the state vector (only matters if it's an independent Rod)

      if (Rod%typeNum == 0) then               ! free Rod type
      
         states(1:6)   = 0.0_DbKi     ! zero velocities for initialization
         states(7:9)   = Rod%r(:,0)   ! end A position
         states(10:12) = Rod%q        ! rod direction unit vector
      
      else if (abs(Rod%typeNum) ==1 ) then           ! pinned rod type (coupled or attached to something previously via setPinKin)
      
         states(1:3)   = 0.0_DbKi     ! zero velocities for initialization
         states(4:6)   = Rod%q        ! rod direction unit vector
         
      end if
      
      ! note: this may also be called by a coupled rod (type = -1) in which case states will be empty
      
      
   END SUBROUTINE Rod_Initialize
   !--------------------------------------------------------------




   ! set kinematics for Rods ONLY if they are attached to a body (including a coupled body) or coupled (otherwise shouldn't be called)
   !--------------------------------------------------------------
   SUBROUTINE Rod_SetKinematics(Rod, r6_in, v6_in, a6_in, t, m)

      Type(MD_Rod),     INTENT(INOUT)  :: Rod            ! the Rod object
      Real(DbKi),       INTENT(IN   )  :: r6_in(6)       ! 6-DOF position
      Real(DbKi),       INTENT(IN   )  :: v6_in(6)       ! 6-DOF velocity
      Real(DbKi),       INTENT(IN   )  :: a6_in(6)       ! 6-DOF acceleration (only used for coupled rods)
      Real(DbKi),       INTENT(IN   )  :: t              ! instantaneous time
      TYPE(MD_MiscVarType),  INTENT(INOUT)  :: m         ! passing along all mooring objects

      INTEGER(IntKi)                   :: l

      Rod%time = t    ! store current time

      
      if (abs(Rod%typeNum) == 2) then ! rod rigidly coupled to a body, or ground, or coupling point
         Rod%r6 = r6_in
         Rod%v6 = v6_in
         Rod%a6 = a6_in
         
         call ScaleVector(Rod%r6(4:6), 1.0_DbKi, Rod%r6(4:6)); ! enforce direction vector to be a unit vector
         
         ! since this rod has no states and all DOFs have been set, pass its kinematics to dependent Lines
         CALL Rod_SetDependentKin(Rod, t, m)
      
      else if (abs(Rod%typeNum) == 1) then ! rod end A pinned to a body, or ground, or coupling point
      
         ! set Rod *end A only* kinematics based on BCs (linear model for now) 
         Rod%r6(1:3) = r6_in(1:3)
         Rod%v6(1:3) = v6_in(1:3)
         Rod%a6(1:3) = a6_in(1:3)

         
         ! Rod is pinned so only end A is specified, rotations are left alone and will be 
         ! handled, along with passing kinematics to dependent lines, by separate call to setState
      
      else
         print *, "Error: Rod_SetKinematics called for a free Rod in MoorDyn."  ! <<<
      end if

   
      ! update Rod direction unit vector (simply equal to last three entries of r6, presumably these were set elsewhere for pinned Rods)
       Rod%q = Rod%r6(4:6)
      
         

   END SUBROUTINE Rod_SetKinematics
   !--------------------------------------------------------------

   ! pass the latest states to the rod if it has any DOFs/states (then update rod end kinematics including attached lines)
   !--------------------------------------------------------------
   SUBROUTINE Rod_SetState(Rod, X, t, m)

      Type(MD_Rod),          INTENT(INOUT)  :: Rod        ! the Rod object
      Real(DbKi),            INTENT(IN   )  :: X(:)       ! state vector section for this line
      Real(DbKi),            INTENT(IN   )  :: t          ! instantaneous time
      TYPE(MD_MiscVarType),  INTENT(INOUT)  :: m          ! passing along all mooring objects

      INTEGER(IntKi)                        :: J          ! index
   

      ! for a free Rod, there are 12 states:
      ! [ x, y, z velocity of end A, then rate of change of u/v/w coordinates of unit vector pointing toward end B,
      ! then x, y, z coordinate of end A, u/v/w coordinates of unit vector pointing toward end B]

      ! for a pinned Rod, there are 6 states (rotational only):
      ! [ rate of change of u/v/w coordinates of unit vector pointing toward end B,
      ! then u/v/w coordinates of unit vector pointing toward end B]
      
      
      ! store current time
      Rod%time = t


      ! copy over state values for potential use during derivative calculations
      if (Rod%typeNum == 0) then                         ! free Rod type
      
         ! CALL ScaleVector(X(10:12), 1.0, X(10:12))  ! enforce direction vector to be a unit vector <<<< can't do this with FAST frameowrk, could be a problem!!
         
         ! TODO: add "controller" adjusting state derivatives of X(10:12) to artificially force X(10:12) to remain a unit vector <<<<<<<<<<<

         
         Rod%r6(1:3) = X(7:9)                         ! (end A coordinates)
         Rod%v6(1:3) = X(1:3)                         ! (end A velocity, unrotated axes) 
         CALL ScaleVector(X(10:12), 1.0_DbKi, Rod%r6(4:6)) !Rod%r6(4:6) = X(10:12)                    ! (Rod direction unit vector)
         Rod%v6(4:6) = X(4:6)                         ! (rotational velocities about unrotated axes) 
         
         
         CALL Rod_SetDependentKin(Rod, t, m)
      
      else if (abs(Rod%typeNum) == 1) then                       ! pinned rod type (coupled or attached to something)t previously via setPinKin)
      
         !CALL ScaleVector(X(4:6), 1.0, X(4:6))      ! enforce direction vector to be a unit vector
         
         
         CALL ScaleVector(X(4:6), 1.0_DbKi, Rod%r6(4:6)) !Rod%r6(3+J) = X(3+J) ! (Rod direction unit vector)
         Rod%v6(4:6) = X(1:3)                    ! (rotational velocities about unrotated axes) 
         
         
         CALL Rod_SetDependentKin(Rod, t, m)
      
      else
         print *, "Error: Rod::setState called for a non-free rod type in MoorDyn"   ! <<<
      end if

      ! update Rod direction unit vector (simply equal to last three entries of r6)
      Rod%q = Rod%r6(4:6)
      
   END SUBROUTINE Rod_SetState
   !--------------------------------------------------------------


   ! Set the Rod end kinematics then set the kinematics of dependent objects (any attached lines).
   ! This also determines the orientation of zero-length rods.
   !--------------------------------------------------------------
   SUBROUTINE Rod_SetDependentKin(Rod, t, m)

      Type(MD_Rod),          INTENT(INOUT)  :: Rod            ! the Rod object
      Real(DbKi),            INTENT(IN   )  :: t              ! instantaneous time
      TYPE(MD_MiscVarType),  INTENT(INOUT)  :: m              ! passing along all mooring objects (for simplicity, since Bodies deal with Rods and Connections)

      INTEGER(IntKi)                        :: l              ! index of segments or nodes along line
      INTEGER(IntKi)                        :: J              ! index
      INTEGER(IntKi)                        :: N              ! number of segments
   
      REAL(DbKi)                            :: qEnd(3)        ! unit vector of attached line end segment, following same direction convention as Rod's q vector
      REAL(DbKi)                            :: EIend          ! bending stiffness of attached line end segment
      REAL(DbKi)                            :: dlEnd          ! stretched length of attached line end segment
      REAL(DbKi)                            :: qMomentSum(3)  ! summation of qEnd*EI/dl_stretched (with correct sign) for each attached line
         

      ! Initialize variables         
      qMomentSum = 0.0_DbKi

      ! in future pass accelerations here too? <<<<
   
      N = Rod%N

      ! from state values, set positions of end nodes 
      ! end A
      Rod%r(:,0)  = Rod%r6(1:3)  ! positions
      Rod%rd(:,0) = Rod%v6(1:3)  ! velocities
      
      !print *, Rod%r6(1:3)
      !print *, Rod%r(:,0)
      
      if (Rod%N > 0) then  ! set end B nodes only if the rod isn't zero length
         CALL transformKinematicsAtoB(Rod%r6(1:3), Rod%r6(4:6), Rod%UnstrLen, Rod%v6, Rod%r(:,N), Rod%rd(:,N))   ! end B    
      end if

      ! pass end node kinematics to any attached lines (this is just like what a Connection does, except for both ends)
      DO l=1,Rod%nAttachedA
         CALL Line_SetEndKinematics(m%LineList(Rod%attachedA(l)), Rod%r(:,0), Rod%rd(:,0), t, Rod%TopA(l))
      END DO
      DO l=1,Rod%nAttachedB
         CALL Line_SetEndKinematics(m%LineList(Rod%attachedB(l)), Rod%r(:,N), Rod%rd(:,N), t, Rod%TopB(l))
      END DO


      ! if this is a zero-length Rod, get bending moment-related information from attached lines and compute Rod's equilibrium orientation
      if (N==0) then
      
         DO l=1,Rod%nAttachedA
         
            CALL Line_GetEndSegmentInfo(m%LineList(Rod%attachedA(l)), qEnd, EIend, dlEnd, Rod%TopA(l))
            
            qMomentSum = qMomentSum + qEnd*EIend/dlEnd  ! add each component to the summation vector
            
         END DO

         DO l=1,Rod%nAttachedB
         
            CALL Line_GetEndSegmentInfo(m%LineList(Rod%attachedB(l)), qEnd, EIend, dlEnd, Rod%TopB(l))
            
            qMomentSum = qMomentSum + qEnd*EIend/dlEnd  ! add each component to the summation vector
            
         END DO
         
         ! solve for line unit vector that balances all moments (unit vector of summation of qEnd*EI/dl_stretched over each line)
         CALL ScaleVector(qMomentSum, 1.0_DbKi, Rod%q)
      END IF

      ! pass Rod orientation to any attached lines (this is just like what a Connection does, except for both ends)
      DO l=1,Rod%nAttachedA
         CALL Line_SetEndOrientation(m%LineList(Rod%attachedA(l)), Rod%q, Rod%TopA(l), 0)
      END DO
      DO l=1,Rod%nAttachedB
         CALL Line_SetEndOrientation(m%LineList(Rod%attachedB(l)), Rod%q, Rod%TopB(l), 1)
      END DO
      
   END SUBROUTINE Rod_SetDependentKin
   !--------------------------------------------------------------

   !--------------------------------------------------------------
   SUBROUTINE Rod_GetStateDeriv(Rod, Xd, m, p)

      Type(MD_Rod),          INTENT(INOUT)  :: Rod              ! the Rod object
      Real(DbKi),            INTENT(INOUT)  :: Xd(:)            ! state derivative vector section for this line
      TYPE(MD_MiscVarType),  INTENT(INOUT)  :: m         ! passing along all mooring objects (for simplicity, since Bodies deal with Rods and Connections)
      TYPE(MD_ParameterType),INTENT(IN   )  :: p                ! Parameters
      
      !TYPE(MD_MiscVarType), INTENT(INOUT)  :: m       ! misc/optimization variables

      INTEGER(IntKi)                        :: J                ! index
      
      Real(DbKi)                            :: Fnet     (6)     ! net force and moment about reference point
      Real(DbKi)                            :: M_out    (6,6)   ! mass matrix about reference point
      
      Real(DbKi)                            :: acc(6)           ! 6DOF acceleration vector about reference point
      
      Real(DbKi)                            :: Mcpl(3)          ! moment in response to end A acceleration due to inertial coupling
      
      Real(DbKi)                            :: y_temp (6)       ! temporary vector for LU decomposition
      Real(DbKi)                            :: LU_temp(6,6)     ! temporary matrix for LU decomposition
      
      ! Initialize some things to zero
      y_temp  = 0.0_DbKi
! FIXME: should LU_temp be set to M_out before calling LUsolve?????
      LU_temp = 0.0_DbKi

      CALL Rod_GetNetForceAndMass(Rod, Rod%r(:,0), Fnet, M_out, m, p)
                  
                  

   ! TODO: add "controller" adjusting state derivatives of X(10:12) to artificially force X(10:12) to remain a unit vector <<<<<<<<<<<

      ! fill in state derivatives
      IF (Rod%typeNum == 0) THEN                         ! free Rod type, 12 states  
         
         ! solve for accelerations in [M]{a}={f} using LU decomposition
         CALL LUsolve(6, M_out, LU_temp, Fnet, y_temp, acc)
         
         Xd(7:9) = Rod%v6(1:3)  !Xd[6 + I] = v6[  I];       ! dxdt = V   (velocities)
         Xd(1:6) = acc          !Xd[    I] = acc[  I];      ! dVdt = a   (accelerations) 
                                !Xd[3 + I] = acc[3+I];        ! rotational accelerations
      
         ! rate of change of unit vector components!!  CHECK!   <<<<<
         Xd(10) =                - Rod%v6(6)*Rod%r6(5) + Rod%v6(5)*Rod%r6(6) ! i.e.  u_dot_x = -omega_z*u_y + omega_y*u_z
         Xd(11) =  Rod%v6(6)*Rod%r6(4)                 - Rod%v6(4)*Rod%r6(6) ! i.e.  u_dot_y =  omega_z*u_x - omega_x*u_z
         Xd(12) = -Rod%v6(5)*Rod%r6(4) + Rod%v6(4)*Rod%r6(5)                 ! i.e.  u_dot_z = -omega_y*u_x - omega_x*u_y

         ! store accelerations in case they're useful as output
         Rod%a6 = acc

      ELSE                            ! pinned rod, 6 states (rotational only)
      
         ! account for moment in response to end A acceleration due to inertial coupling (off-diagonal sub-matrix terms)
         !Fnet(4:6) = Fnet(4:6) - MATMUL(M_out(4:6,1:3), Rod%a6(1:3))  ! <<<check that it's the right submatrix <<<
         Fnet(4:6) = Fnet(4:6) - MATMUL(M_out(1:3,4:6), Rod%a6(1:3))  ! <<< THIS order is stable. Weird. <<<
         ! ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ the above line seems to be causing the stability problems for USFLOWT! <<<<
         
         ! solve for accelerations in [M]{a}={f} using LU decomposition
         CALL LUsolve(3, M_out(4:6,4:6), LU_temp(4:6,4:6), Fnet(4:6), y_temp(4:6), acc(4:6))
         ! Note: solving for rotational DOFs only - excluding translational and off-diagonal 3x3 terms -
         
         Xd(1:3) = acc(4:6)   !   Xd[    I] = acc[3+I];          ! rotational accelerations
         
         ! rate of change of unit vector components!!  CHECK!   <<<<<
         Xd(4) =                - Rod%v6(6)*Rod%r6(5) + Rod%v6(5)*Rod%r6(6) ! i.e.  u_dot_x = -omega_z*u_y + omega_y*u_z
         Xd(5) =  Rod%v6(6)*Rod%r6(4)                 - Rod%v6(4)*Rod%r6(6) ! i.e.  u_dot_y =  omega_z*u_x - omega_x*u_z
         Xd(6) = -Rod%v6(5)*Rod%r6(4) + Rod%v6(4)*Rod%r6(5)                 ! i.e.  u_dot_z = -omega_y*u_x - omega_x*u_y
      
         ! store angular accelerations in case they're useful as output
         Rod%a6(4:6) = acc(4:6)
      
      END IF
      
      ! Note: accelerations that are dependent on parent objects) will not be known to this object 
      !       (only those of free DOFs are coupled DOFs are known in this approach).
   
      ! check for NaNs (should check all state derivatives, not just first 6)
      DO J = 1, 6
         IF (Is_NaN(Xd(J))) THEN
            print *, "NaN detected at time ", Rod%time, " in Rod ",Rod%IdNum
            IF (wordy > 1) THEN
               print *, " state derivatives:"
               print *, Xd
               
               print *, "r0"
               print *, Rod%r(:,0)
               print *, "F"
               print *, Fnet
               print *, "M"
               print *, M_out
               print *, "acc"
               print *, acc            
            END IF
            
            EXIT
         END IF
      END DO

   END SUBROUTINE Rod_GetStateDeriv
   !--------------------------------------------------------------


   ! calculate the forces on the rod, including from attached lines
   !--------------------------------------------------------------
   SUBROUTINE Rod_DoRHS(Rod, m, p)

      Type(MD_Rod),          INTENT(INOUT)  :: Rod            ! the Rodion object
      TYPE(MD_MiscVarType),  INTENT(INOUT)  :: m           ! passing along all mooring objects
      TYPE(MD_ParameterType),INTENT(IN   )  :: p              ! Parameters
      
      !TYPE(MD_MiscVarType), INTENT(INOUT)  :: m       ! misc/optimization variables

      INTEGER(IntKi)             :: l            ! index of attached lines
      INTEGER(IntKi)             :: I,J,K        ! index
      
      
      INTEGER(IntKi)             :: N            ! number of rod elements for convenience

      Real(DbKi)                 :: phi, beta, sinPhi, cosPhi, tanPhi, sinBeta, cosBeta   ! various orientation things
      Real(DbKi)                 :: k_hat(3)     ! unit vector (redundant, not used) <<<<
      Real(DbKi)                 :: Ftemp        ! temporary force component
      Real(DbKi)                 :: Mtemp        ! temporary moment component

      Real(DbKi)                 :: m_i, v_i     ! 
      Real(DbKi)                 :: zeta         ! wave elevation above/below a given node
      !Real(DbKi)                 :: h0           ! distance along rod centerline from end A to the waterplane     
      Real(DbKi)                 :: deltaL       ! submerged length of a given segment
      Real(DbKi)                 :: Lsum         ! cumulative length along rod axis from bottom
      Real(DbKi)                 :: dL           ! length attributed to node
      Real(DbKi)                 :: VOF          ! fraction of volume associated with node that is submerged
      
      Real(DbKi)                 :: Vi(3)        ! relative flow velocity over a node
      Real(DbKi)                 :: SumSqVp, SumSqVq, MagVp, MagVq
      Real(DbKi)                 :: Vp(3), Vq(3) ! transverse and axial components of water velocity at a given node     
      Real(DbKi)                 :: ap(3), aq(3) ! transverse and axial components of water acceleration at a given node
      Real(DbKi)                 :: Fnet_i(3)    ! force from an attached line
      Real(DbKi)                 :: Mnet_i(3)    ! moment from an attached line
      Real(DbKi)                 :: Mass_i(3,3)  ! mass from an attached line

      ! used in lumped 6DOF calculations:
      Real(DbKi)                 :: rRel(  3)              ! relative position of each node i from rRef      
      Real(DbKi)                 :: OrMat(3,3)             ! rotation matrix to rotate global z to rod's axis
      Real(DbKi)                 :: F6_i(6)                ! a node's contribution to the total force vector
      Real(DbKi)                 :: M6_i(6,6)              ! a node's contribution to the total mass matrix
      Real(DbKi)                 :: I_l                    ! axial inertia of rod
      Real(DbKi)                 :: I_r                    ! radial inertia of rod about CG
      Real(DbKi)                 :: Imat_l(3,3)            ! inertia about CG aligned with Rod axis
      Real(DbKi)                 :: Imat(3,3)              ! inertia about CG in global frame     
      Real(DbKi)                 :: h_c                    ! location of CG along axis
      Real(DbKi)                 :: r_c(3)                 ! 3d location of CG relative to node A      
      Real(DbKi)                 :: Fcentripetal(3)        ! centripetal force
      Real(DbKi)                 :: Mcentripetal(3)        ! centripetal moment

      Real(DbKi)                 :: depth                  ! local interpolated depth from bathymetry grid


      N = Rod%N

      ! ------------------------------ zero some things --------------------------
      
      Rod%Mext = 0.0_DbKi  ! zero the external moment sum

      Lsum = 0.0_DbKi

      
      ! ---------------------------- initial rod and node calculations ------------------------

      ! calculate some orientation information for the Rod as a whole
      call GetOrientationAngles(Rod%r( :,0), Rod%r( :,N), phi, sinPhi, cosPhi, tanPhi, beta, sinBeta, cosBeta, k_hat)
 
      ! save to internal roll and pitch variables for use in output <<< should check these, make Euler angles isntead of independent <<<
      Rod%roll  = -180.0/Pi * phi*sinBeta
      Rod%pitch =  180.0/Pi * phi*cosBeta

      ! set interior node positions and velocities (stretch the nodes between the endpoints linearly) (skipped for zero-length Rods)
      DO i=1,N-1
         Rod%r( :,i) =  Rod%r( :,0) + (Rod%r( :,N) - Rod%r( :,0)) * (REAL(i)/REAL(N))
         Rod%rd(:,i) =  Rod%rd(:,0) + (Rod%rd(:,N) - Rod%rd(:,0)) * (REAL(i)/REAL(N))
         
      
         Rod%V(i) = 0.25*pi * Rod%d*Rod%d * Rod%l(i) ! volume attributed to segment
      END DO


   ! --------------------------------- apply wave kinematics ------------------------------------

    !  IF (p%WaterKin == 1)  THEN ! wave kinematics interpolated from global grid in Waves object
    !     DO i=0,N
    !        CALL getWaveKin(p, Rod%r(1,i), Rod%r(2,i), Rod%r(3,i), Rod%time, m%WaveTi, Rod%U(:,i), Rod%Ud(:,i), Rod%zeta(i), Rod%PDyn(i))
    !        !F(i) = 1.0 ! set VOF value to one for now (everything submerged - eventually this should be element-based!!!) <<<<
    !        ! <<<< currently F is not being used and instead a VOF variable is used within the node loop
    !     END DO
    !  END IF


    !  ! wave kinematics not implemented yet <<<
    !  ap = 0.0_DbKi
    !  aq = 0.0_DbKi
    !  ! set U and Ud herem as well as pDyn and zeta...
    !  Rod%U    = 0.0_DbKi
    !  Rod%Ud   = 0.0_DbKi
    !  pDyn = 0.0_DbKi
    !  zeta = 0.0_DbKi
      
      ! >>> remember to check for violated conditions, if there are any... <<<
           
      zeta = Rod%zeta(N)! just use the wave elevation computed at the location of the top node for now
      
      if ((Rod%r(3,0) < zeta) .and. (Rod%r(3,N) > zeta)) then    ! check if it's crossing the water plane (should also add some limits to avoid near-horizontals at some point)
         Rod%h0 = (zeta - Rod%r(3,0))/Rod%q(3)                       ! distance along rod centerline from end A to the waterplane
      else if (Rod%r(3,0) < zeta) then
         Rod%h0 = Rod%UnstrLen                                   ! fully submerged case   <<<<<< remove the 2.0 and double check there are no if statements that get changed <<<<
      else
         Rod%h0 = 0.0_DbKi                                           ! fully unsubmerged case (ever applicable?)
      end if

   
      ! -------------------------- loop through all the nodes -----------------------------------
      DO I = 0, N
      
      
         ! ------------------ calculate added mass matrix for each node -------------------------
      
         ! get mass and volume considering adjacent segment lengths
         IF (I==0) THEN
            dL  = 0.5*Rod%l(1)
            m_i = 0.25*Pi * Rod%d*Rod%d * dL *Rod%rho     ! (will be zero for zero-length Rods)
            v_i = 0.5 *Rod%V(1)
         ELSE IF (I==N) THEN
            dL  = 0.5*Rod%l(N)
            m_i = 0.25*pi * Rod%d*Rod%d * dL *Rod%rho
            v_i = 0.5*Rod%V(N)
         ELSE
            dL  = 0.5*(Rod%l(I) + Rod%l(I+1))
            m_i = 0.25*pi * Rod%d*Rod%d * dL *Rod%rho
            v_i = 0.5 *(Rod%V(I) + Rod%V(I+1))
         END IF

         ! get scalar for submerged portion                  
         IF (Lsum + dL <= Rod%h0) THEN    ! if fully submerged 
            VOF = 1.0_DbKi
         ELSE IF (Lsum < Rod%h0) THEN    ! if partially below waterline 
            VOF = (Rod%h0 - Lsum)/dL
         ELSE                        ! must be out of water
            VOF = 0.0_DbKi
         END IF
         
         Lsum = Lsum + dL            ! add length attributed to this node to the total

         ! build mass and added mass matrix
         DO J=1,3
            DO K=1,3
               IF (J==K) THEN
                  Rod%M(K,J,I) = m_i + VOF*p%rhoW*v_i*( Rod%Can*(1 - Rod%q(J)*Rod%q(K)) + Rod%Cat*Rod%q(J)*Rod%q(K) )
               ELSE
                  Rod%M(K,J,I) = VOF*p%rhoW*v_i*( Rod%Can*(-Rod%q(J)*Rod%q(K)) + Rod%Cat*Rod%q(J)*Rod%q(K) )
               END IF
            END DO
         END DO
         
         ! <<<< what about accounting for offset of half segment from node location for end nodes? <<<<
         
         
!         CALL Inverse3by3(Rod%S(:,:,I), Rod%M(:,:,I))             ! invert mass matrix


         ! ------------------  CALCULATE FORCES ON EACH NODE ----------------------------

         if (N > 0) then ! the following force calculations are only nonzero for finite-length rods (skipping for zero-length Rods)
         
            ! >>> no nodal axial elasticity loads calculated since it's assumed rigid, but should I calculate tension/compression due to other loads? <<<

            ! weight (now only the dry weight)
            Rod%W(:,I) = (/ 0.0_DbKi, 0.0_DbKi, -m_i * p%g /)   ! assuming g is positive
            
            ! buoyance (now calculated based on outside pressure, for submerged portion only)
            ! radial buoyancy force from sides
            Ftemp = -VOF * 0.25*Pi*dL*Rod%d*Rod%d * p%rhoW*p%g * sinPhi
            Rod%Bo(:,I) = (/ Ftemp*cosBeta*cosPhi, Ftemp*sinBeta*cosPhi, -Ftemp*sinPhi /)            

            !relative flow velocities
            DO J = 1, 3
               Vi(J) = Rod%U(J,I) - Rod%rd(J,I)                               ! relative flow velocity over node -- this is where wave velicites would be added
            END DO

            ! decomponse relative flow into components
            SumSqVp = 0.0_DbKi                                         ! start sums of squares at zero
            SumSqVq = 0.0_DbKi
            DO J = 1, 3
               Vq(J) = DOT_PRODUCT( Vi , Rod%q ) * Rod%q(J);            ! tangential relative flow component
               Vp(J) = Vi(J) - Vq(J)                                    ! transverse relative flow component
               SumSqVq = SumSqVq + Vq(J)*Vq(J)
               SumSqVp = SumSqVp + Vp(J)*Vp(J)
            END DO
            MagVp = sqrt(SumSqVp)                                       ! get magnitudes of flow components
            MagVq = sqrt(SumSqVq)

            ! transverse and tangenential drag
            Rod%Dp(:,I) = VOF * 0.5*p%rhoW*Rod%Cdn*    Rod%d* dL * MagVp * Vp
            Rod%Dq(:,I) = 0.0_DbKi ! 0.25*p%rhoW*Rod%Cdt* Pi*Rod%d* dL * MagVq * Vq <<< should these axial side loads be included?

            ! fluid acceleration components for current node
            aq = DOT_PRODUCT(Rod%Ud(:,I), Rod%q) * Rod%q  ! tangential component of fluid acceleration
            ap = Rod%Ud(:,I) - aq                         ! normal component of fluid acceleration
            ! transverse Froude-Krylov force
            Rod%Ap(:,I) = VOF * p%rhoW*(1.0+Rod%Can)* v_i * ap  ! 
            ! axial Froude-Krylov force
            Rod%Aq(:,I) = 0.0_DbKi  ! p%rhoW*(1.0+Rod%Cat)* v_i * aq  ! <<< just put a taper-based term here eventually?

            ! dynamic pressure
            Rod%Pd(:,I) = 0.0_DbKi  ! assuming zero for sides for now, until taper comes into play
            
            ! bottom contact (stiffness and damping, vertical-only for now)  - updated Nov 24 for general case where anchor and fairlead ends may deal with bottom contact forces
            ! interpolate the local depth from the bathymetry grid
            CALL getDepthFromBathymetry(m%BathymetryGrid, m%BathGrid_Xs, m%BathGrid_Ys, Rod%r(1,I), Rod%r(2,I), depth)
            
            IF (Rod%r(3,I) < -depth) THEN
               IF (I==0) THEN
                  Rod%B(3,I) = ( (-depth - Rod%r(3,I))*p%kBot - Rod%rd(3,I)*p%cBot) * 0.5*Rod%d*(            Rod%l(I+1) ) 
               ELSE IF (I==N) THEN
                  Rod%B(3,I) = ( (-depth - Rod%r(3,I))*p%kBot - Rod%rd(3,I)*p%cBot) * 0.5*Rod%d*(Rod%l(I)               ) 
               ELSE
                  Rod%B(3,I) = ( (-depth - Rod%r(3,I))*p%kBot - Rod%rd(3,I)*p%cBot) * 0.5*Rod%d*(Rod%l(I) + Rod%l(I+1) ) 
               END IF
               ! IF (I==0) THEN
               !    Rod%B(3,I) = ( (-p%WtrDpth - Rod%r(3,I))*p%kBot - Rod%rd(3,I)*p%cBot) * 0.5*Rod%d*(            Rod%l(I+1) ) 
               ! ELSE IF (I==N) THEN
               !    Rod%B(3,I) = ( (-p%WtrDpth - Rod%r(3,I))*p%kBot - Rod%rd(3,I)*p%cBot) * 0.5*Rod%d*(Rod%l(I)               ) 
               ! ELSE
               !    Rod%B(3,I) = ( (-p%WtrDpth - Rod%r(3,I))*p%kBot - Rod%rd(3,I)*p%cBot) * 0.5*Rod%d*(Rod%l(I) + Rod%l(I+1) ) 
               ! END IF
            ELSE
               Rod%B(3,I) = 0.0_DbKi
            END IF
            
         ELSE    ! zero-length (N=0) Rod case
         
            ! >>>>>>>>>>>>>> still need to check handling of zero length rods <<<<<<<<<<<<<<<<<<<
         
            ! for zero-length rods, make sure various forces are zero
            Rod%W  = 0.0_DbKi
            Rod%Bo = 0.0_DbKi
            Rod%Dp = 0.0_DbKi
            Rod%Dq= 0.0_DbKi
            Rod%B = 0.0_DbKi
            Rod%Pd = 0.0_DbKi
            
         END IF
         
         
         ! ------ now add forces, moments, and added mass from Rod end effects (these can exist even if N==0) -------
         
         ! end A
         IF ((I==0) .and. (Rod%h0 > 0.0_ReKi)) THEN    ! if this is end A and it is submerged 
         
         ! >>> eventually should consider a VOF approach for the ends    hTilt = 0.5*Rod%d/cosPhi <<<
         
            ! buoyancy force
            Ftemp = -VOF * 0.25*Pi*Rod%d*Rod%d * p%rhoW*p%g*Rod%r(3,I)
            Rod%Bo(:,I) = Rod%Bo(:,I) + (/ Ftemp*cosBeta*sinPhi, Ftemp*sinBeta*sinPhi, Ftemp*cosPhi /) 
         
            ! buoyancy moment
            Mtemp = -VOF * 1.0/64.0*Pi*Rod%d**4 * p%rhoW*p%g * sinPhi 
            Rod%Mext = Rod%Mext + (/ Mtemp*sinBeta, -Mtemp*cosBeta, 0.0_DbKi /) 
         
            ! axial drag
            Rod%Dq(:,I) = Rod%Dq(:,I) + VOF * 0.25* Pi*Rod%d*Rod%d * p%rhoW*Rod%CdEnd * MagVq * Vq
         
         
            ! >>> what about rotational drag?? <<<   eqn will be  Pi* Rod%d**4/16.0 omega_rel?^2...  *0.5 * Cd...

            ! Froud-Krylov force
            Rod%Aq(:,I) = Rod%Aq(:,I) + VOF * p%rhoW*(1.0+Rod%CaEnd)* (2.0/3.0*Pi*Rod%d**3 /8.0) * aq
            
            ! dynamic pressure force
            Rod%Pd(:,I) = Rod%Pd(:,I) + VOF * 0.25* Pi*Rod%d*Rod%d * Rod%PDyn(I) * Rod%q
            
            ! added mass
            DO J=1,3
               DO K=1,3
                  IF (J==K) THEN
                     Rod%M(K,J,I) = Rod%M(K,J,I) + VOF*p%rhoW* Rod%CaEnd* (2.0/3.0*Pi*Rod%d**3 /8.0) *Rod%q(J)*Rod%q(K) 
                  ELSE
                     Rod%M(K,J,I) = Rod%M(K,J,I) + VOF*p%rhoW* Rod%CaEnd* (2.0/3.0*Pi*Rod%d**3 /8.0) *Rod%q(J)*Rod%q(K) 
                  END IF
               END DO
            END DO
         
         END IF
            
         IF ((I==N) .and. (Rod%h0 >= Rod%UnstrLen)) THEN    ! if this end B and it is submerged (note, if N=0, both this and previous if statement are true)
         
            ! buoyancy force
            Ftemp = VOF * 0.25*Pi*Rod%d*Rod%d * p%rhoW*p%g*Rod%r(3,I)
            Rod%Bo(:,I) = Rod%Bo(:,I) + (/ Ftemp*cosBeta*sinPhi, Ftemp*sinBeta*sinPhi, Ftemp*cosPhi /) 
         
            ! buoyancy moment
            Mtemp = VOF * 1.0/64.0*Pi*Rod%d**4 * p%rhoW*p%g * sinPhi 
            Rod%Mext = Rod%Mext + (/ Mtemp*sinBeta, -Mtemp*cosBeta, 0.0_DbKi /) 
            
            ! axial drag
            Rod%Dq(:,I) = Rod%Dq(:,I) + VOF * 0.25* Pi*Rod%d*Rod%d * p%rhoW*Rod%CdEnd * MagVq * Vq
            
            ! Froud-Krylov force
            Rod%Aq(:,I) = Rod%Aq(:,I) + VOF * p%rhoW*(1.0+Rod%CaEnd)* (2.0/3.0*Pi*Rod%d**3 /8.0) * aq
            
            ! dynamic pressure force
            Rod%Pd(:,I) = Rod%Pd(:,I) - VOF * 0.25* Pi*Rod%d*Rod%d * Rod%PDyn(I) * Rod%q
            
            ! added mass
            DO J=1,3
               DO K=1,3
                  IF (J==K) THEN
                     Rod%M(K,J,I) = Rod%M(K,J,I) + VOF*p%rhoW* Rod%CaEnd* (2.0/3.0*Pi*Rod%d**3 /8.0) *Rod%q(J)*Rod%q(K) 
                  ELSE
                     Rod%M(K,J,I) = Rod%M(K,J,I) + VOF*p%rhoW* Rod%CaEnd* (2.0/3.0*Pi*Rod%d**3 /8.0) *Rod%q(J)*Rod%q(K) 
                  END IF
               END DO
            END DO
            
         END IF
         
         
         
         ! ---------------------------- total forces for this node -----------------------------
         
         Rod%Fnet(:,I) = Rod%W(:,I) + Rod%Bo(:,I) + Rod%Dp(:,I) + Rod%Dq(:,I) &
                         + Rod%Ap(:,I) + Rod%Aq(:,I) + Rod%Pd(:,I) + Rod%B(:,I)
         

      END DO  ! I  - done looping through nodes


      ! ----- add waterplane moment of inertia moment if applicable -----
      IF ((Rod%r(3,0) < zeta) .and. (Rod%r(3,N) > zeta)) then    ! check if it's crossing the water plane
         Mtemp = 1.0/16.0 *Pi*Rod%d**4 * p%rhoW*p%g * sinPhi * (1.0 + 0.5* tanPhi**2)
         Rod%Mext = Rod%Mext + (/ Mtemp*sinBeta, -Mtemp*cosBeta, 0.0_DbKi /)
      END IF
   
      ! ---------------- now add in forces on end nodes from attached lines ------------------
         
      ! loop through lines attached to end A
      DO l=1,Rod%nAttachedA
         
         CALL Line_GetEndStuff(m%LineList(Rod%attachedA(l)), Fnet_i, Mnet_i, Mass_i, Rod%TopA(l))
         
         ! sum quantitites
         Rod%Fnet(:,0)= Rod%Fnet(:,0) + Fnet_i    ! total force
         Rod%Mext     = Rod%Mext      + Mnet_i    ! externally applied moment
         Rod%M(:,:,0) = Rod%M(:,:,0)  + Mass_i    ! mass at end node
         
      END DO
   
      ! loop through lines attached to end B
      DO l=1,Rod%nAttachedB
         
         CALL Line_GetEndStuff(m%LineList(Rod%attachedB(l)), Fnet_i, Mnet_i, Mass_i, Rod%TopB(l))
         
         ! sum quantitites
         Rod%Fnet(:,N)= Rod%Fnet(:,N) + Fnet_i    ! total force
         Rod%Mext     = Rod%Mext      + Mnet_i    ! externally applied moment
         Rod%M(:,:,N) = Rod%M(:,:,N)  + Mass_i    ! mass at end node
         
      END DO
      
      ! ---------------- now lump everything in 6DOF about end A -----------------------------

      ! question: do I really want to neglect the rotational inertia/drag/etc across the length of each segment?
   
      ! make sure 6DOF quantiaties are zeroed before adding them up
      Rod%F6net = 0.0_DbKi
      Rod%M6net = 0.0_DbKi

      ! now go through each node's contributions, put them about end A, and sum them
      DO i = 0,Rod%N
      
         rRel = Rod%r(:,i) - Rod%r(:,0)   ! vector from reference point to node            
         
         ! convert segment net force into 6dof force about body ref point (if the Rod itself, end A)
         CALL translateForce3to6DOF(rRel, Rod%Fnet(:,i), F6_i)
         
         ! convert segment mass matrix to 6by6 mass matrix about body ref point  (if the Rod itself, end A)
         CALL translateMass3to6DOF(rRel, Rod%M(:,:,i), M6_i)
                  
         ! sum contributions
         Rod%F6net = Rod%F6net + F6_i
         Rod%M6net = Rod%M6net + M6_i
         
      END DO
      
      ! ------------- Calculate some items for the Rod as a whole here -----------------
      
      ! >>> could some of these be precalculated just once? <<<
            
      ! add inertia terms for the Rod assuming it is uniform density (radial terms add to existing matrix which contains parallel-axis-theorem components only)
      I_l = 0.125*Rod%mass * Rod%d*Rod%d     ! axial moment of inertia
      I_r = Rod%mass/12 * (0.75*Rod%d*Rod%d + (Rod%UnstrLen/Rod%N)**2 ) * Rod%N     ! summed radial moment of inertia for each segment individually
      
      !h_c = [value from registry]

      Imat_l(1,1) = I_r   ! inertia about CG in local orientations (as if Rod is vertical)
      Imat_l(2,2) = I_r
      Imat_l(3,3) = I_l
      
      OrMat = CalcOrientation(phi, beta, 0.0_DbKi)        ! get rotation matrix to put things in global rather than rod-axis orientations
      
      Imat = RotateM3(Imat_l, OrMat)  ! rotate to give inertia matrix about CG in global frame
      
      ! these supplementary inertias can then be added the matrix (these are the terms ASIDE from the parallel axis terms)
      Rod%M6net(4:6,4:6) = Rod%M6net(4:6,4:6) + Imat
      

      ! now add centripetal and gyroscopic forces/moments, and that should be everything
      h_c = 0.5*Rod%UnstrLen          ! distance to center of mass
      r_c = h_c*Rod%q                 ! vector to center of mass
      
      ! note that Rod%v6(4:6) is the rotational velocity vector, omega   
      Fcentripetal = 0.0_DbKi !<<<TEMP<<< -cross_product(Rod%v6(4:6), cross_product(Rod%v6(4:6), r_c ))*Rod%mass <<<
      Mcentripetal = 0.0_DbKi !<<<TEMP<<< cross_product(r_c, Fcentripetal) - cross_product(Rod%v6(4:6), MATMUL(Imat,Rod%v6(4:6)))
      
      ! add centripetal force/moment, gyroscopic moment, and any moments applied from lines at either end (might be zero)
      Rod%F6net(1:3) = Rod%F6net(1:3) + Fcentripetal 
      Rod%F6net(4:6) = Rod%F6net(4:6) + Mcentripetal + Rod%Mext
            
      ! Note: F6net saves the Rod's net forces and moments (excluding inertial ones) for use in later output
      !       (this is what the rod will apply to whatever it's attached to, so should be zero moments if pinned).
      !       M6net saves the rod's mass matrix.
      

   END SUBROUTINE Rod_DoRHS
   !=====================================================================



   ! calculate the aggregate 3/6DOF rigid-body loads of a coupled rod including inertial loads
   !--------------------------------------------------------------
   SUBROUTINE Rod_GetCoupledForce(Rod, Fnet_out, m, p)

      Type(MD_Rod),          INTENT(INOUT)  :: Rod         ! the Rod object
      Real(DbKi),            INTENT(  OUT)  :: Fnet_out(6) ! force and moment vector
      TYPE(MD_MiscVarType),  INTENT(INOUT)  :: m           ! passing along all mooring objects
      TYPE(MD_ParameterType),INTENT(IN   )  :: p           ! Parameters
      
      Real(DbKi)                            :: F6_iner(6)   ! inertial reaction force
      
      ! do calculations of forces and masses on each rod node
      CALL Rod_DoRHS(Rod, m, p)

      ! add inertial loads as appropriate (written out in a redundant way just for clarity, and to support load separation in future)
      ! fixed coupled rod
      if (Rod%typeNum == -2) then                          
      
         F6_iner  = -MATMUL(Rod%M6net, Rod%a6)    ! inertial loads      
         Fnet_out = Rod%F6net + F6_iner           ! add inertial loads
      
      ! pinned coupled rod      
      else if (Rod%typeNum == -1) then                     
         ! inertial loads ... from input translational ... and solved rotational ... acceleration
         F6_iner(4:6)  = -MATMUL(Rod%M6net(1:3,1:3), Rod%a6(1:3)) - MATMUL(Rod%M6net(1:3,4:6), Rod%a6(4:6))
         Fnet_out(1:3) = Rod%F6net(1:3) + F6_iner(4:6)     ! add translational inertial loads
         Fnet_out(4:6) = 0.0_DbKi
      else
         print *, "ERROR, Rod_GetCoupledForce called for wrong (non-coupled) rod type!"
      end if
   
   END SUBROUTINE Rod_GetCoupledForce
   !--------------------------------------------------------------
   


   ! calculate the aggregate 6DOF rigid-body force and mass data of the rod 
   !--------------------------------------------------------------
   SUBROUTINE Rod_GetNetForceAndMass(Rod, rRef, Fnet_out, M_out, m, p)

      Type(MD_Rod),          INTENT(INOUT)  :: Rod         ! the Rod object
      Real(DbKi),            INTENT(IN   )  :: rRef(3)     ! global coordinates of reference point (end A for free Rods)
      Real(DbKi),            INTENT(  OUT)  :: Fnet_out(6) ! force and moment vector about rRef
      Real(DbKi),            INTENT(  OUT)  :: M_out(6,6)  ! mass and inertia matrix about rRef
      TYPE(MD_MiscVarType),  INTENT(INOUT)  :: m           ! passing along all mooring objects
      TYPE(MD_ParameterType),INTENT(IN   )  :: p           ! Parameters
      
      Real(DbKi)                 :: rRel(  3)              ! relative position of each node i from rRef      
      
      ! do calculations of forces and masses on each rod node
      CALL Rod_DoRHS(Rod, m, p)

      ! note: Some difference from MoorDyn C here. If this function is called by the Rod itself, the reference point must be end A

      ! shift everything from end A reference to rRef reference point
      
      rRel = Rod%r(:,0) - rRef   ! vector from reference point to end A            
         
      CALL translateForce3to6DOF(rRel, Rod%F6net(1:3), Fnet_out)      ! shift net forces
      Fnet_out(4:6) = Fnet_out(4:6) + Rod%F6net(4:6)               ! add in the existing moments
         
      CALL translateMass6to6DOF(rRel, Rod%M6net, M_out)          ! shift mass matrix to be about ref point
         
      ! >>> do we need to ensure zero moment is passed if it's pinned? <<<
      !if (abs(Rod%typeNum)==1) then
      !   Fnet_out(4:6) = 0.0_DbKi
      !end if

   
   END SUBROUTINE Rod_GetNetForceAndMass
   !--------------------------------------------------------------
   

   ! this function handles assigning a line to a connection node
   SUBROUTINE Rod_AddLine(Rod, lineID, TopOfLine, endB)

      Type(MD_Rod), INTENT (INOUT)   :: Rod        ! the Connection object

      Integer(IntKi),   INTENT( IN )     :: lineID
      Integer(IntKi),   INTENT( IN )     :: TopOfLine
      Integer(IntKi),   INTENT( IN )     :: endB   ! add line to end B if 1, end A if 0

      if (endB==1) then   ! attaching to end B

         IF (wordy > 0) Print*, "L", lineID, "->R", Rod%IdNum , "b"
         
         IF (Rod%nAttachedB <10) THEN ! this is currently just a maximum imposed by a fixed array size.  could be improved.
            Rod%nAttachedB = Rod%nAttachedB + 1  ! add the line to the number connected
            Rod%AttachedB(Rod%nAttachedB) = lineID
            Rod%TopB(Rod%nAttachedB) = TopOfLine  ! attached to line ... 1 = top/fairlead(end B), 0 = bottom/anchor(end A)
         ELSE
            Print*, "too many lines connected to Rod ", Rod%IdNum, " in MoorDyn!"
         END IF

      else              ! attaching to end A
      
         IF (wordy > 0) Print*, "L", lineID, "->R", Rod%IdNum , "a"
         
         IF (Rod%nAttachedA <10) THEN ! this is currently just a maximum imposed by a fixed array size.  could be improved.
            Rod%nAttachedA = Rod%nAttachedA + 1  ! add the line to the number connected
            Rod%AttachedA(Rod%nAttachedA) = lineID
            Rod%TopA(Rod%nAttachedA) = TopOfLine  ! attached to line ... 1 = top/fairlead(end B), 0 = bottom/anchor(end A)
         ELSE
            Print*, "too many lines connected to Rod ", Rod%IdNum, " in MoorDyn!"
         END IF
         
      end if

   END SUBROUTINE Rod_AddLine


   ! this function handles removing a line from a connection node
   SUBROUTINE Rod_RemoveLine(Rod, lineID, TopOfLine, endB,  rEnd, rdEnd)

      Type(MD_Rod), INTENT (INOUT)  :: Rod        ! the Connection object

      Integer(IntKi),   INTENT( IN )     :: lineID
      Integer(IntKi),   INTENT(  OUT)    :: TopOfLine
      Integer(IntKi),   INTENT( IN )     :: endB   ! end B if 1, end A if 0
      REAL(DbKi),       INTENT(INOUT)    :: rEnd(3)
      REAL(DbKi),       INTENT(INOUT)    :: rdEnd(3)
      
      Integer(IntKi)    :: l,m,J
      
      if (endB==1) then   ! attaching to end B
         
         DO l = 1,Rod%nAttachedB    ! look through attached lines
         
            IF (Rod%AttachedB(l) == lineID) THEN   ! if this is the line's entry in the attachment list
            
               TopOfLine = Rod%TopB(l);                ! record which end of the line was attached
               
               DO m = l,Rod%nAttachedB-1 
               
                  Rod%AttachedB(m) = Rod%AttachedB(m+1)  ! move subsequent line links forward one spot in the list to eliminate this line link
                  Rod%TopB(     m) =      Rod%TopB(m+1) 
               
                  Rod%nAttachedB = Rod%nAttachedB - 1                      ! reduce attached line counter by 1
               
                  ! also pass back the kinematics at the end
                  DO J = 1,3
                     rEnd( J) = Rod%r( J,Rod%N)
                     rdEnd(J) = Rod%rd(J,Rod%N)
                  END DO
                  
                  print*, "Detached line ", lineID, " from Rod ", Rod%IdNum, " end B"
                  
                  EXIT
               END DO
               
               IF (l == Rod%nAttachedB) THEN   ! detect if line not found
                  print *, "Error: failed to find line to remove during RemoveLine call to Rod ", Rod%IdNum, ". Line ", lineID
               END IF
            END IF
         END DO
         
      else              ! attaching to end A
              
        DO l = 1,Rod%nAttachedA    ! look through attached lines
         
            IF (Rod%AttachedA(l) == lineID) THEN   ! if this is the line's entry in the attachment list
            
               TopOfLine = Rod%TopA(l);                ! record which end of the line was attached
               
               DO m = l,Rod%nAttachedA-1 
               
                  Rod%AttachedA(m) = Rod%AttachedA(m+1)  ! move subsequent line links forward one spot in the list to eliminate this line link
                  Rod%TopA(     m) =      Rod%TopA(m+1) 
               
                  Rod%nAttachedA = Rod%nAttachedA - 1                      ! reduce attached line counter by 1
               
                  ! also pass back the kinematics at the end
                  DO J = 1,3
                     rEnd( J) = Rod%r( J,0)
                     rdEnd(J) = Rod%rd(J,0)
                  END DO
                  
                  print*, "Detached line ", lineID, " from Rod ", Rod%IdNum, " end A"
                  
                  EXIT
               END DO
               
               IF (l == Rod%nAttachedA) THEN   ! detect if line not found
                  print *, "Error: failed to find line to remove during RemoveLine call to Rod ", Rod%IdNum, ". Line ", lineID
               END IF
            END IF
         END DO
      
      end if
      
   END SUBROUTINE Rod_RemoveLine




END MODULE MoorDyn_Rod
