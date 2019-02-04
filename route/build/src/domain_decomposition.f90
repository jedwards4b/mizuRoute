MODULE domain_decomposition_module

USE nrtype
USE public_var
USE pfafstetter_module
USE dataTypes,         ONLY: var_clength   ! character type:   var(:)%dat
USE dataTypes,         ONLY: var_ilength   ! integer type:     var(:)%dat
USE dataTypes,         ONLY: basin         !
USE dataTypes,         ONLY: reach         !
USE dataTypes,         ONLY: reach_class   !
USE var_lookup,        ONLY: ixPFAF        ! index of variables for the pfafstetter code
USE var_lookup,        ONLY: ixNTOPO       ! index of variables for the netowork topolgy
USE nr_utility_module, ONLY: indexx        ! Num. Recipies utilities
USE nr_utility_module, ONLY: indexTrue     ! Num. Recipies utilities
USE nr_utility_module, ONLY: arth          ! Num. Recipies utilities
USE nr_utility_module, ONLY: findIndex     ! Num. Recipies utilities

! updated and saved data
USE globalData, only : domains             ! domain data structure - for each domain, pfaf codes and list of segment indices
USE globalData, only : nDomain             ! count of decomposed domains (tributaries + mainstems)
USE globalData, only : node_id             ! node id for each domain

implicit none

private

public :: classify_river_basin_omp
public :: classify_river_basin_mpi

contains

 subroutine classify_river_basin_mpi(nSeg, structPFAF, structNTOPO, maxSegs, ierr, message)
   ! MPI domain decomposition wrapper
   implicit none
   ! Input variables
   integer(i4b),                   intent(in)  :: nSeg                   ! number of stream segments
   type(var_clength), allocatable, intent(in)  :: structPFAF(:)          ! pfafstetter code
   type(var_ilength), allocatable, intent(in)  :: structNTOPO(:)         ! network topology
   integer(i4b),                   intent(in)  :: maxSegs                ! threshold number of tributary reaches
   ! Output variables
   integer(i4b),                   intent(out) :: ierr
   character(len=strLen),          intent(out) :: message                ! error message
   ! Local variables
   character(len=strLen)                       :: cmessage               ! error message from subroutine
   character(len=32)                           :: pfafs(nSeg)            ! pfaf_codes for all the segment
   character(len=32)                           :: pfafOutlet             ! pfaf_codes for a outlet segment
   character(len=32)                           :: pfafCommon             ! common pfaf_codes over the entire basin
   character(len=32), allocatable              :: pfafOutlets(:)         ! pfaf_codes for outlet segments
   integer(i4b)                                :: level                  ! number of digits of common pfaf codes given pfaf code at outlet reach
   integer(i4b)                                :: downIndex(nSeg)        ! downstream segment index for all the segments
   integer(i4b)                                :: segIndex(nSeg)         ! reach index for all the segments
   integer(i4b)                                :: segId(nSeg)            ! reach id for all the segments
   integer(i4b)                                :: nOuts                  ! number of outlets
   integer(i4b)                                :: iSeg,iOut              ! loop indices
   integer(i4b)                                :: ix                     ! loop indices
   integer(i4b)                                :: idx                     ! loop indices
   logical(lgt)                                :: seglgc(nSeg)

   ierr=0; message='classify_river_basin_mpi/'

   nDomain = 0

   forall(iSeg=1:nSeg) pfafs(iSeg)     = structPFAF(iSeg)%var(ixPFAF%code)%dat(1)
   forall(iSeg=1:nSeg) downIndex(iSeg) = structNTOPO(iSeg)%var(ixNTOPO%downSegIndex)%dat(1)
   forall(iSeg=1:nSeg) segIndex(iSeg)  = structNTOPO(iSeg)%var(ixNTOPO%segIndex)%dat(1)
   forall(iSeg=1:nSeg) segId(iSeg)     = structNTOPO(iSeg)%var(ixNTOPO%segId)%dat(1)

   ! Number of outlets
   nOuts=count(downIndex<0)

   allocate(pfafOutlets(nOuts), stat=ierr)
   if(ierr/=0)then; message=trim(message)//'problem allocating [pfasOutlets]'; return; endif

   ! Outlet information - pfaf code
   pfafOutlets = pack(pfafs, downIndex<0)

   do iOut = 1,nOuts
     pfafOutlet = adjustl(pfafOutlets(iOut))

     ! Identify pfaf level for a river basin given outlet pfaf
     call get_common_pfaf(pfafs, pfafOutlet, level, ierr, cmessage)
     if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

     ! perform domain decomposition for a river basin
     pfafCommon = trim(pfafOutlet(1:level))   ! to be removed
     call decomposition(pfafs, segIndex, downIndex, structNTOPO, pfafCommon, maxSegs, ierr, cmessage)
     if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
   end do

   ! Assign domains to node
   call assign_node(11, ierr, cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

!   ! --------------------------------------------------
!   !  print to check
!   seglgc = .true.
!   do ix = 1,nDomain
!    associate (segIndexSub => domains(ix)%segIndex)
!    do iSeg = 1,size(segIndexSub)
!     idx = findIndex(segId, segId(segIndexSub(iSeg)), -999)
!     if (idx/=-999)then
!      seglgc(idx) = .false.
!     else
!      print*, 'Cannot find ', segId(segIndexSub(iSeg))
!     endif
!     write(*,"(I9,A,A,A,A,A,I4,A,I2)") segId(segIndexSub(iSeg)),',',trim(adjustl(pfafs(segIndexSub(iSeg)))),',',trim(domains(ix)%pfaf),',',size(segIndexSub),',',node_id(ix)
!    end do
!    end associate
!   end do
!   ! --------------------------------------------------

 end subroutine classify_river_basin_mpi


 subroutine assign_node(nNodes, ierr, message)
   ! assign domains into computing nodes
   implicit none
   ! Input variables
   integer(i4b),                   intent(in)  :: nNodes           ! nNodes
   ! Output variables
   integer(i4b),                   intent(out) :: ierr
   character(len=strLen),          intent(out) :: message          ! error message
   ! Local variables
   character(len=strLen)                       :: cmessage         ! error message from subroutine
   integer(i4b)                                :: nTribSeg         ! number of tributary segments
   integer(i4b)                                :: nWork(nNodes-1)  ! number of tributary workload for each node
   integer(i4b)                                :: ixNode(1)        ! node id where work load is minimum
   integer(i4b)                                :: ix,ixx           ! loop indices
   integer(i4b),allocatable                    :: nSubSeg(:)       !
   integer(i4b),allocatable                    :: rnkRnDomain(:)   ! ranked domain based on size
   integer(i4b)                                :: nTrib            !
   integer(i4b)                                :: nEven            !
   integer(i4b)                                :: nSmallTrib       ! number of small tributaries to be processed in root node
   logical(lgt),allocatable                    :: isAssigned(:)

   ierr=0; message='assign_node/'

   allocate(nSubSeg(nDomain),rnkRnDomain(nDomain),isAssigned(nDomain),node_id(nDomain),stat=ierr)
   if(ierr/=0)then; message=trim(message)//'problem allocating [nSubSeg,rnkRnDomain,isAssigned,node_id]'; return; endif

   ! rank domain by number of segments
   ! count segments for each domain - nSubSeg
   ! count tributary domains - nTrib
   ! count total segments from tributary domains - nTribSeg
   ! rank domains based on nSubSeg - rnkRnDomain
   nTribSeg = 0
   nTrib = 0
   do ix = 1,nDomain
    nSubSeg(ix) = size(domains(ix)%segIndex)
    if (domains(ix)%pfaf(1:1)/='-') then
     nTribSeg = nTribSeg + nSubSeg(ix)
     nTrib = nTrib + 1
    endif
   end do
   call indexx(nSubSeg,rnkRnDomain)

   ! root node is used to process mainstem and small tributaries
   ! going through tributaries from the smallest, and accumulate number of tributary segments (nSmallTrib) up to "nEven"
   ! count a number of tributaries that are processed in mainstem cores
   nEven = nTribSeg/nNodes
   nSmallTrib=0
   isAssigned = .false.
   do ix = 1,nDomain
    ixx = rnkRnDomain(ix)
    if (domains(ixx)%pfaf(1:1)/='-') then
     nSmallTrib = nSmallTrib + nSubSeg(ixx)
     node_id(ixx) = 0
     isAssigned(ixx) = .true.
     if(nSmallTrib > nEven) exit
    endif
   end do

   ! Distribute "large" tributary to distributed cores
   nWork(1:nNodes-1) = 0
   do ix = nDomain,1,-1  ! Going through domain from the largest size
    ixx = rnkRnDomain(ix)
    if (.not. isAssigned(ixx)) then
     if (domains(ixx)%pfaf(1:1)=='-') then   ! if domain is mainstem
      node_id(ixx) = 0
      isAssigned(ixx) = .true.
     elseif (domains(ixx)%pfaf(1:1)/='-') then ! if domain is tributary
      ixNode = minloc(nWork)
      nWork(ixNode(1)) = nWork(ixNode(1))+size(domains(ixx)%segIndex)
      node_id(ixx) = ixNode(1)
      isAssigned(ixx) = .true.
     endif
    endif
   end do

   ! check
   do ix = 1,nDomain
     if (.not.isAssigned(ix)) then
       write(cmessage, "(A,I1,A)") 'Domain ', ix, 'is not assigned to any nodes'
       ierr = 10; message=trim(message)//trim(cmessage); return
     endif
   enddo

 end subroutine assign_node


 recursive subroutine decomposition(pfafs, segIndex, downIndex, structNTOPO, pfafCode, maxSegs, ierr, message)
   implicit none
   ! Input variables
   character(len=32),              intent(in)  :: pfafs(:)        ! pfaf_code list
   integer(i4b),                   intent(in)  :: downIndex(:)    ! downstream segment index for all the segments
   integer(i4b),                   intent(in)  :: segIndex(:)     ! reach index for all the segments
   type(var_ilength), allocatable, intent(in)  :: structNTOPO(:)         ! network topology
   character(len=32),              intent(in)  :: pfafCode        ! common pfaf codes within a river basin
   integer(i4b)                                :: maxSegs         ! maximum number of reaches in basin
   ! Output variables
   integer(i4b),                   intent(out) :: ierr
   character(len=strLen),          intent(out) :: message         ! error message
   ! Local variables
   character(len=strLen)                       :: cmessage        ! error message from subroutine
   integer(i4b)                                :: iPfaf,iSeg,jSeg ! loop indices
   integer(i4b)                                :: nMatch          ! count for pfafs matching with pfafCode
   integer(i4b)                                :: nSeg            ! number of stream segments
   logical(lgt),     allocatable               :: isMatch(:)      ! logical to indicate xxxxx
   character(len=32)                           :: pfafCodeTmp     ! copy of pfafCode
   character(len=32),allocatable               :: subPfafs(:)     ! subset of pfaf_codes
   integer(i4b),     allocatable               :: subSegIndex(:)  ! subset of segment indices
   integer(i4b),     allocatable               :: subDownIndex(:) ! subset of donwstream segment original indices (indice are based on original segIndex)
   integer(i4b),     allocatable               :: downIndexNew(:) ! subset of downstream segment indices within subset of sgement indices
   character(len=32)                           :: subPfaf         ! pfaf_code appended by next level
   character(len=32)                           :: pfaf            ! a pfaf_code
   character(len=1)                            :: cPfaf           ! character digit

   ierr=0; message='decomposition/'

   pfafCodeTmp = trim(pfafCode)
   nSeg = size(pfafs)

   do iPfaf = 1,9
     write(cPfaf, '(I1)') iPfaf
     pfafCodeTmp = trim(pfafCodeTmp)//cPfaf

     if (.not. allocated(isMatch)) then
       allocate(isMatch(nSeg), stat=ierr)
       if(ierr/=0)then; message=trim(message)//'problem allocating [isMatch]'; return; endif
     endif
     isMatch(:) = .false.

     do iSeg = 1,size(pfafs)
       pfaf = adjustl(pfafs(iSeg))
       subPfaf = pfaf(1:len(trim(pfafCodeTmp)))
       if (subPfaf == pfafCodeTmp) then
         isMatch(iSeg) = .true.
       end if
     end do
     nMatch = count(isMatch)

     print*,'pfafCode, number of matches = ', trim(pfafCodeTmp), nMatch

     if (nMatch==0) then
       pfafCodeTmp = pfafCodeTmp(1:len(trim(pfafCodeTmp))-1)  ! decrement
       cycle
     end if

     if (nMatch < maxSegs) then
       print*,'Aggregate: nMatch less than nThreh = ', maxSegs
       allocate(subPfafs(nMatch), subDownIndex(nMatch), subSegIndex(nMatch), downIndexNew(nMatch), stat=ierr)
       if(ierr/=0)then; message=trim(message)//'problem allocating [subPfafs, subDownIndex, subSegIndex, downIndexNew]'; return; endif
       subPfafs     = pack(pfafs, isMatch)
       subSegIndex  = pack(segIndex, isMatch)
       subDownIndex = pack(downIndex, isMatch)
       ! redo donwstream index
       downIndexNew=-999
       do iSeg = 1, nMatch
         do jSeg = 1, nMatch
           if (subDownIndex(iSeg) == subSegIndex(jSeg)) then
             downIndexNew(iSeg) = jSeg
             exit
           end if
         end do
       end do
       call aggregate(pfafCodeTmp, subPfafs, subSegIndex, downIndexNew, structNTOPO, ierr, cmessage) ! populate reach classification data structure
       if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
       deallocate(subPfafs, subDownIndex, subSegIndex, downIndexNew, stat=ierr)
       if(ierr/=0)then; message=trim(message)//'problem deallocating [subPfafs, subDownIndex, subSegIndex, downIndexNew]'; return; endif
     else
       print*,'Disaggregate: nMatch more than maxSegs = ', maxSegs
       call decomposition(pfafs, segIndex, downIndex, structNTOPO, pfafCodeTmp, maxSegs, ierr, cmessage)
       if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
     end if

     pfafCodeTmp = pfafCodeTmp(1:len(trim(pfafCodeTmp))-1) ! decrement

   end do

 end subroutine decomposition


 subroutine aggregate(pfafCode, pfafs, segIndex, downIndex, structNTOPO, ierr, message)

   ! Given a basin defined by "pfafCode", identify mainstem and tributaries.
   ! Assign minu pfafCode (pfafCode=968 -> -968) to mainstem reaches, and
   ! Identify a mainstem code for each tributary and assing that mainstem code to the reaches in the tributary
   ! Modified data structure -> domains
   ! domains(:)%pfaf           code for mainstem reach or tributaries
   !           %segIndex(:)    indices of reaches that belong to pfaf

   implicit none
   ! Input variables
   character(len=32),              intent(in)  :: pfafCode                  ! Common pfaf codes within a river basin
   character(len=32),              intent(in)  :: pfafs(:)                  ! pfaf codes within a basin
   integer(i4b),                   intent(in)  :: downIndex(:)              ! downstream reach indices for reaches within a basin
   integer(i4b),                   intent(in)  :: segIndex(:)               ! reach indices for reaches within a basin
   type(var_ilength), allocatable, intent(in)  :: structNTOPO(:)            ! network topology
   ! Output variables
   integer(i4b),                   intent(out) :: ierr                      ! error code
   character(len=strLen),          intent(out) :: message                   ! error message
   ! Local variables
   character(len=strLen)                       :: cmessage                  ! error message from subroutine
   character(len=32)                           :: mainCode                  ! mainstem code
   integer(i4b)                                :: iTrib                     ! loop indices
   integer(i4b)                                :: nSeg,nTrib,nMainstem      ! number of reaches, tributaries, and mainstems, respectively
   integer(i4b)                                :: nUpSegs                   ! numpber of upstream segments
   integer(i4b)                                :: pfafLen
   integer(i4b)                                :: pfaf_old, pfaf_new
   integer(i4b),allocatable                    :: ixSubset(:)               ! subset indices based on logical array from global index array
   character(len=32),allocatable               :: trib_outlet_pfafs(:)
   logical(lgt)                                :: isInterbasin, isHeadwater ! logical to indicate the basin is inter basin or headwater
   logical(lgt),allocatable                    :: isTribOutlet(:)
   logical(lgt),allocatable                    :: isMainstem(:)
   logical(lgt),allocatable                    :: isMainstem2d(:,:)

   ierr=0; message='aggregate/'

   ! Initialization
   nSeg = size(pfafs)

   ! get pfaf old and pfaf new
   pfafLen = len(trim(pfafCode))
   read(pfafCode(pfafLen-1:pfafLen-1),'(I1)') pfaf_old
   read(pfafCode(pfafLen:pfafLen),'(I1)') pfaf_new

   ! check if an interbasin or headwater
   isInterbasin = (mod(pfaf_new, 2)==1)
   isHeadwater  = (mod(pfaf_old, 2)==0 .and. pfaf_new==9)

   if (isInterbasin .and. (.not. isHeadwater)) then  ! if a river reach is in inter-basin and not headwater

     ! 1. Populate mainstem segments
     nDomain = nDomain + 1
     ! record the code for mainstem
     domains(nDomain)%pfaf = '-'//trim(pfafCode)
     ! get mainstem reaches (isMainstem(nSeg) logical array)
     call find_mainstems(pfafCode, pfafs, isMainstem, ierr, cmessage)
     if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
     ! Count mainstem reaches and allocate for segIndex array
     nMainstem = count(isMainstem)
     allocate(domains(nDomain)%segIndex(nMainstem), stat=ierr)
     if(ierr/=0)then; message=trim(message)//'problem allocating [domains(nDomain)%segIndex]'; return; endif
     ! Identify mainstem reach indices based on the basin reaches
     allocate(ixSubset(nMainstem), stat=ierr)
     if(ierr/=0)then; message=trim(message)//'problem allocating [ixSubset]'; return; endif
     ixSubset = pack(arth(1,1,nSeg),isMainstem)
     domains(nDomain)%segIndex = segIndex(ixSubset)
     deallocate(ixSubset, stat=ierr)
     if(ierr/=0)then; message=trim(message)//'problem deallocating [ixSubset]'; return; endif

     ! 2. Populate tributary segments
     ! Get logical array indicating tributary outlet segments (size = nSeg)
     isMainstem2d = spread(isMainstem,2,1)
     call lgc_tributary_outlet(isMainstem2d, downIndex, isTribOutlet, ierr, cmessage)
     if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
     ! Get indices of tributary outlet segments (size = number of tributaries)
     nTrib = count(isTribOutlet)
     ! idenfity tributary outlet reaches
     allocate(ixSubset(nTrib), trib_outlet_pfafs(nTrib), stat=ierr)
     if(ierr/=0)then; message=trim(message)//'problem allocating [ixSubset, trib_outlet_pfafs]'; return; endif
     ixSubset = pack(arth(1,1,nSeg),isTribOutlet)
     trib_outlet_pfafs = pfafs(ixSubset)
     ! loop through each tributary to identify 1) tributary code (== mainstem code in tributary)
     !                                         2) reaches in tributary
     do iTrib = 1,nTrib
       nDomain = nDomain + 1
       mainCode = mainstem_code(trim(trib_outlet_pfafs(iTrib)))
       domains(nDomain)%pfaf = mainCode
       associate(upSegIndex => structNTOPO(segIndex(ixSubset(iTrib)))%var(ixNTOPO%allUpSegIndices)%dat)
       nUpSegs = size(upSegIndex)
       allocate(domains(nDomain)%segIndex(nUpSegs), stat=ierr)
       if(ierr/=0)then; message=trim(message)//'problem allocating [domains(nDomain)%segIndex]'; return; endif
       domains(nDomain)%segIndex = upSegIndex
       end associate
     end do
     deallocate(ixSubset, stat=ierr)
     if(ierr/=0)then; message=trim(message)//'problem deallocating [ixSubset]'; return; endif

   else    ! a river reach is in inter-basin or headwater

     nDomain = nDomain + 1
     allocate(domains(nDomain)%segIndex(size(segIndex)), stat=ierr)
     if(ierr/=0)then; message=trim(message)//'problem allocating domains(nDomain)%segIndex for interbasin or headwater'; return; endif
     domains(nDomain)%pfaf = trim(pfafCode)
     domains(nDomain)%segIndex = segIndex

   end if

 end subroutine aggregate


 subroutine classify_river_basin_omp(nSeg, structPFAF, structNTOPO, river_basin, maxSegs, ierr, message)
  ! Identify tributary basin and mainstems using river network data and pfafstetter code
  ! Output: return populated basin dataType
  implicit none
  ! Input variables
  integer(i4b),                   intent(in)  :: nSeg                   ! number of stream segments
  type(var_clength), allocatable, intent(in)  :: structPFAF(:)          ! pfafstetter code
  type(var_ilength), allocatable, intent(in)  :: structNTOPO(:)         ! network topology
  integer(i4b)                  , intent(in)  :: maxSegs                ! maximum reach number in each tributary
  ! Output variables
  type(basin),       allocatable, intent(out) :: river_basin(:)         ! river basin data
  integer(i4b),                   intent(out) :: ierr
  character(len=strLen),          intent(out) :: message                ! error message
  ! Local variables
  type(reach), allocatable                    :: tmpMainstem(:)         ! temporary reach structure for mainstem
  character(len=strLen)                       :: cmessage               ! error message from subroutine
  character(len=32)                           :: pfafs(nSeg)            ! pfaf_codes for all the segment
  character(len=32), allocatable              :: pfaf_out(:)            ! pfaf_codes for outlet segments
  character(len=32)                           :: upPfaf                 ! pfaf_code for one upstream segment
  character(len=32)                           :: outMainstemCode
  logical(lgt),      allocatable              :: mainstems(:,:)         ! logical to indicate segment is mainstem at each level
  logical(lgt),      allocatable              :: updated_mainstems(:,:) ! logical to indicate segment is mainstem at each level
  logical(lgt),      allocatable              :: lgc_trib_outlet(:)     ! logical to indicate segment is outlet of tributary
  logical(lgt)                                :: done                   ! logical
  integer(i4b)                                :: maxLevel=20
  integer(i4b)                                :: downIndex(nSeg)        ! downstream segment index for all the segments
  integer(i4b)                                :: segIndex(nSeg)         ! reach index for all the segments
  integer(i4b)                                :: segOrder(nSeg)         ! reach order for all the segments
  integer(i4b)                                :: rankSegOrder(nSeg)     ! ranked reach order for all the segments
  integer(i4b), allocatable                   :: segIndex_out(:)        ! index for outlet segment
  integer(i4b)                                :: level                  ! manstem level
  integer(i4b)                                :: nMains,nUpSegMain      ! number of mainstems in a level, and number of segments in a mainstem
  integer(i4b)                                :: nOuts                  ! number of outlets
  integer(i4b)                                :: nUpSegs                ! number of upstream segments for a specified segment
  integer(i4b)                                :: nTrib                  ! Number of Tributary basins
  integer(i4b), allocatable                   :: nSegTrib(:)            ! Number of segments in each tributary basin
  integer(i4b), allocatable                   :: nSegMain(:)            ! number of mainstem only segments excluding tributary segments
  integer(i4b), allocatable                   :: rankTrib(:)            ! index for ranked tributary based on num. of upstream reaches
  integer(i4b), allocatable                   :: rankMain(:)            ! index for ranked mainstem based on num. of mainstem reaches
  integer(i4b), allocatable                   :: segOrderTrib(:)        ! index for tributary upstream reach order
  integer(i4b), allocatable                   :: segMain(:)             ! index for segment in one mainstem
  integer(i4b), allocatable                   :: segOrderMain(:)        ! index for ordered segment in one mainstem
  integer(i4b), allocatable                   :: trPos(:)               ! tributary outlet indices
  integer(i4b), allocatable                   :: msPos(:)               ! mainstem indices
  integer(i4b)                                :: iSeg,jSeg,iOut         ! loop indices
  integer(i4b)                                :: iTrib,jTrib            ! loop indices
  integer(i4b)                                :: iMain,jMain            ! loop indices

  ierr=0; message='classify_river_basin_omp/'

  forall(iSeg=1:nSeg) pfafs(iSeg)     = structPFAF(iSeg)%var(ixPFAF%code)%dat(1)
  forall(iSeg=1:nSeg) downIndex(iSeg) = structNTOPO(iSeg)%var(ixNTOPO%downSegIndex)%dat(1)
  forall(iSeg=1:nSeg) segIndex(iSeg)  = structNTOPO(iSeg)%var(ixNTOPO%segIndex)%dat(1)
  forall(iSeg=1:nSeg) segOrder(iSeg)  = structNTOPO(iSeg)%var(ixNTOPO%rchOrder)%dat(1)

  call indexx(segOrder,rankSegOrder)

  ! Number of outlets
  nOuts=count(downIndex<0)

  allocate(river_basin(nOuts), stat=ierr)
  if(ierr/=0)then; message=trim(message)//'problem allocating river_basin'; return; endif
  allocate(pfaf_out(nOuts), segIndex_out(nOuts), stat=ierr)
  if(ierr/=0)then; message=trim(message)//'problem allocating [pfaf_out, segIndex_out]'; return; endif

  ! Outlet information - pfaf code and segment index
  pfaf_out = pack(pfafs, downIndex<0)
  segIndex_out = pack(segIndex, downIndex<0)

  do iOut = 1,nOuts

    print*, 'working on outlet:'//trim(adjustl(pfaf_out(iOut)))

    allocate(river_basin(iOut)%level(maxLevel), stat=ierr)
    if(ierr/=0)then; message=trim(message)//'problem allocating river_basin(iOut)%mainstem'; return; endif

    river_basin(iOut)%outIndex = segIndex_out(iOut)

!    call system_clock(startTime)
    ! Identify pfaf level given a river network
    call get_common_pfaf(pfafs, pfaf_out(iOut), level, ierr, cmessage)
    if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
!    call system_clock(endTime)
!    elapsedTime = real(endTime-startTime, kind(dp))/10e8_dp
!    write(*,"(A,1PG15.7,A)") '       elapsed-time [get_common_pfaf] = ', elapsedTime, ' s'

!    call system_clock(startTime)
    ! Identify mainstem segments at all levels (up to maxLevel)
    call lgc_mainstems(pfafs, pfaf_out(iOut), maxLevel, mainstems, ierr, cmessage)
    if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
!    call system_clock(endTime)
!    elapsedTime = real(endTime-startTime, kind(dp))/10e8_dp
!    write(*,"(A,1PG15.7,A)") '      elapsed-time [lgc_mainstems] = ', elapsedTime, ' s'

    ! Initial assignment of mainstem segments
    allocate(updated_mainstems(size(mainstems,1),size(mainstems,2)), stat=ierr)
    updated_mainstems = .false.
    updated_mainstems(:,level) = mainstems(:,level)

    ! Identify the lowest level mainstem segment index
    call indexTrue(mainstems(:,level), msPos)

    allocate(river_basin(iOut)%level(level)%mainstem(1), stat=ierr)
    if(ierr/=0)then; message=trim(message)//'problem allocating river_basin(iOut)%mainstem(level)%mainstem'; return; endif
    allocate(river_basin(iOut)%level(level)%mainstem(1)%segIndex(size(msPos)), stat=ierr)
    if(ierr/=0)then; message=trim(message)//'problem allocating river_basin(:)%mainstem(:)%segIndex'; return; endif
    allocate(segOrderMain(size(msPos)), stat=ierr)
    if(ierr/=0)then; message=trim(message)//'problem allocating segOrderMain'; return; endif

    ! Compute reach order for mainstem segment
    call indexx(rankSegOrder(msPos), segOrderMain)

    river_basin(iOut)%level(level)%mainstem(1)%segIndex(1:size(msPos))  = msPos(segOrderMain)
    river_basin(iOut)%level(level)%mainstem(1)%nRch = size(msPos)

!    call system_clock(startTime)
    ! Identify tributary outlets into a mainstem at the lowest level
    !  i.e. the segment that is not on any mainstems AND flows into any mainstem segments
    call lgc_tributary_outlet(mainstems(:,:level), downIndex, lgc_trib_outlet, ierr, cmessage)
    if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
!    call system_clock(endTime)
!    elapsedTime = real(endTime-startTime, kind(dp))/10e8_dp
!    write(*,"(A,1PG15.7,A)") '      elapsed-time [lgc_tributary_outlet] = ', elapsedTime, ' s'

    deallocate(mainstems, segIndex_out, segOrderMain, stat=ierr)
    if(ierr/=0)then; message=trim(message)//'problem deallocating mainstems'; return; endif

    do
      level = level + 1
      print*, 'Mainstem Level = ', level

      ! number of tributary basins
      nTrib = count(lgc_trib_outlet)

      allocate(nSegTrib(nTrib),rankTrib(nTrib), stat=ierr)
      if(ierr/=0)then; message=trim(message)//'problem allocating nSegTrib'; return; endif

      ! Extract array elements with only tributary outlet (keep indices in master array
      call indexTrue(lgc_trib_outlet, trPos)

      ! number of tributary segments
      do iTrib=1,nTrib
        nSegTrib(iTrib) = size(structNTOPO(trPos(iTrib))%var(ixNTOPO%allUpSegIndices)%dat)
      end do

      ! rank the tributary outlets based on number of upstream segments
      call indexx(nSegTrib, rankTrib)

      ! Identify mainstems of large tributaries (# of segments > maxSeg) and update updated_mainstems.
      done=.true.
      nMains = 0
      do iTrib=nTrib,1,-1
        if (nSegTrib(rankTrib(iTrib)) > maxSegs) then
           write(*,'(A,A,I5)') 'Exceed maximum number of segments: ', pfafs(trPos(rankTrib(iTrib))), nSegTrib(rankTrib(iTrib))
           nMains=nMains+1
           done=.false.
        else
           exit
        endif
      end do

      if (done) then ! if no mainstem/tributary updated, update tributary reach info, and then exist loop

!        print*, 'Main/Trib update finished, Now Update tributary reach ....'

        allocate(river_basin(iOut)%tributary(nTrib), stat=ierr)
        if(ierr/=0)then; message=trim(message)//'problem allocating river_basin%tributary'; return; endif

        do iTrib=nTrib,1,-1

!          call system_clock(startTime)

          jTrib = nTrib - iTrib + 1

!          if (mod(jTrib,1000)==0) print*, 'jTrib = ',jTrib

          allocate(river_basin(iOut)%tributary(jTrib)%segIndex(nSegTrib(rankTrib(iTrib))), stat=ierr)
          if(ierr/=0)then; message=trim(message)//'problem allocating river_basin(:)%tributary%segIndex'; return; endif
          allocate(segOrderTrib(nSegTrib(rankTrib(iTrib))), stat=ierr)
          if(ierr/=0)then; message=trim(message)//'problem allocating segOrderTrib'; return; endif

          ! compute reach order for tributary segments
          associate( segIndexTrib => structNTOPO(trPos(rankTrib(iTrib)))%var(ixNTOPO%allUpSegIndices)%dat)
          call indexx(rankSegOrder(segIndexTrib), segOrderTrib)
          river_basin(iOut)%tributary(jTrib)%segIndex(:) = segIndexTrib(segOrderTrib)
          end associate

          ! compute number of segments in each tributary
          river_basin(iOut)%tributary(jTrib)%nRch = nSegTrib(rankTrib(iTrib))

          deallocate(segOrderTrib, stat=ierr)
          if(ierr/=0)then; message=trim(message)//'problem deallocating segOrderTrib'; return; endif

!          if (mod(jTrib,1000)==0) then
!          call system_clock(endTime)
!          elapsedTime = real(endTime-startTime, kind(dp))/10e8_dp
!          write(*,"(A,1PG15.7,A)") ' total elapsed-time [Update Trib. reach] = ', elapsedTime, ' s'
!          endif

        end do

        exit

      else ! if mainstem/tributary updated, store mainstem reach info at current level, update lgc_trib_outlet and go onto next level

        allocate(river_basin(iOut)%level(level)%mainstem(nMains), stat=ierr)
        if(ierr/=0)then; message=trim(message)//'problem allocating river_basin(iOut)%level(level)%mainstem'; return; endif
        allocate(tmpMainstem(nMains), stat=ierr)
        if(ierr/=0)then; message=trim(message)//'problem allocating tmpMainstem'; return; endif
        allocate(nSegMain(nMains), rankMain(nMains), stat=ierr)
        if(ierr/=0)then; message=trim(message)//'problem allocating [nSegMain,rankMain]'; return; endif

        do iTrib=nTrib,nTrib-nMains+1,-1

!          if (mod(nTrib-iTrib+1,10)==0) print*, 'iTrib = ', nTrib-iTrib+1
!          call system_clock(startTime)

          ! Outlet mainstem code
          outMainstemCode = mainstem_code(pfafs(trPos(rankTrib(iTrib))))

          associate(upSegIndex => structNTOPO(trPos(rankTrib(iTrib)))%var(ixNTOPO%allUpSegIndices)%dat)

          nUpSegs = size(upSegIndex)

          allocate(segMain(nUpSegs), stat=ierr)
          if(ierr/=0)then; message=trim(message)//'problem allocating [segMain]'; return; endif

          nUpSegMain = 0
          do jSeg=1,nUpSegs
            upPfaf = pfafs(upSegIndex(jSeg))
            if (trim(mainstem_code(upPfaf)) /= trim(outMainstemCode)) cycle
            updated_mainstems(upSegIndex(jSeg),level) = .true.
            nUpSegMain = nUpSegMain+1
            segMain(nUpSegMain) = upSegIndex(jSeg)
          end do

          allocate(tmpMainstem(nTrib-iTrib+1)%segIndex(nUpSegMain), stat=ierr)
          if(ierr/=0)then; message=trim(message)//'problem allocating tmpMainstem(nUpSegMain)%segIndex'; return; endif
          allocate(segOrderMain(nUpSegMain), stat=ierr)
          if(ierr/=0)then; message=trim(message)//'problem allocating segOrderMain'; return; endif

          call indexx(rankSegOrder(segMain(1:nUpSegMain)), segOrderMain)
          tmpMainstem(nTrib-iTrib+1)%segIndex(:) = segMain(segOrderMain)
          nSegMain(nTrib-iTrib+1) = nUpSegMain

          end associate

          deallocate(segMain, segOrderMain, stat=ierr)
          if(ierr/=0)then; message=trim(message)//'problem deallocating [segMain, segOrderMain]'; return; endif

!          if (mod(nTrib-iTrib+1,10)==0) then
!          call system_clock(endTime)
!          elapsedTime = real(endTime-startTime, kind(dp))/10e8_dp
!          write(*,"(A,1PG15.7,A)") ' total elapsed-time [update trib each loop] = ', elapsedTime, ' s'
!          endif

        end do ! tributary loop

        ! rank the mainstem based on number of upstream segments (excluding tributaries)
        call indexx(nSegMain, rankMain)
        ! populate mainstem segment component in river basin structure
        do iMain=1,nMains
          jMain=rankMain(nMains-iMain+1)
          allocate(river_basin(iOut)%level(level)%mainstem(iMain)%segIndex(nSegMain(jMain)), stat=ierr)
          if(ierr/=0)then; message=trim(message)//'problem allocating river_basin(iOut)%level(level)%mainstem(iMain)%segIndex'; return; endif
          river_basin(iOut)%level(level)%mainstem(iMain)%segIndex(:) = tmpMainstem(jMain)%segIndex(:)
          river_basin(iOut)%level(level)%mainstem(iMain)%nRch = nSegMain(jMain)
        enddo

        ! update lgc_trib_outlet based on added mainstem
        call lgc_tributary_outlet(updated_mainstems(:,:level), downIndex, lgc_trib_outlet, ierr, cmessage)
        if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

        deallocate(tmpMainstem, nSegMain, rankMain, stat=ierr)
        if(ierr/=0)then; message=trim(message)//'problem deallocating [tmpMainstem,nSegMain,rankMain]'; return; endif
        deallocate(nSegTrib, rankTrib, stat=ierr)
        if(ierr/=0)then; message=trim(message)//'problem deallocating [nSegTrib, rankTrib]'; return; endif

      endif
    end do ! end of tributary update loop

  end do ! outlet loop

 end subroutine classify_river_basin_omp


end module domain_decomposition_module
