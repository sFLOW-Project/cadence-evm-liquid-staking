export const LSP_VAULT_EVENTS_ABI = [
  'event StakeRequested(uint256 indexed id, address indexed user, uint256 amount)',
  'event StakeCancelled(uint256 indexed id, address indexed user, uint256 refundWei)',
  'event StakeFulfilled(uint256 indexed id, address indexed user, uint256 sFlowAmount)',
  'event UnstakeRequested(uint256 indexed id, address indexed user, uint256 amount)',
  'event UnstakeConfirmed(uint256 indexed id, address indexed user, uint256 flowAmount, uint256 unlockEpoch)',
  'event UnstakeFulfilled(uint256 indexed id, address indexed user, uint256 amount)',
  'event UnstakeCancelled(uint256 indexed id, address indexed user, uint256 amount)',
  'event WithdrawalClaimed(address indexed user, address indexed recipient, uint256 amount)',
  'event BackingUpdated(uint256 totalFlowStaked, uint256 totalSFlowSupply)',
  'event ConfigUpdated(tuple(uint256 minRequestAmount, bool isStakingPaused, bool isUnstakingPaused, uint256 protocolFee, uint256 slippageTolerance) oldConfig, tuple(uint256 minRequestAmount, bool isStakingPaused, bool isUnstakingPaused, uint256 protocolFee, uint256 slippageTolerance) newConfig)',
  'event MinRequestAmountUpdated(uint256 oldMinRequestAmount, uint256 newMinRequestAmount)',
  'event IsStakingPausedUpdated(bool oldIsStakingPaused, bool newIsStakingPaused)',
  'event IsUnstakingPausedUpdated(bool oldIsUnstakingPaused, bool newIsUnstakingPaused)',
  'event ProtocolFeeUpdated(uint256 oldProtocolFee, uint256 newProtocolFee)',
  'event SlippageToleranceUpdated(uint256 oldSlippageTolerance, uint256 newSlippageTolerance)',
] as const

export const RELAYER_EVENT_NAMES = new Set([
  'StakeRequested',
  'StakeCancelled',
  'StakeFulfilled',
  'UnstakeRequested',
  'UnstakeConfirmed',
  'UnstakeFulfilled',
  'UnstakeCancelled',
])
