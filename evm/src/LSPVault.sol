// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FlowReceipt} from "./FlowReceipt.sol";
import {LSPVaultConfig} from "./LSPVaultConfig.sol";
import {ILSPVault} from "./interfaces/ILSPVault.sol";

/**
 * @title LSPVault
 * @notice A contract that allows users to deposit/stake/unstake/withdraw Flow on the Cadence LSP.
 * @dev Intended to be deployed by the Flow COA, to allow keeper to interact through COA.
 */
contract LSPVault is LSPVaultConfig, ILSPVault {
    using SafeERC20 for IERC20;

    /// Address of the router COA.
    address public immutable ROUTER_COA;

    /// Address of the Flow receipt token.
    FlowReceipt public immutable FLOW_RECEIPT;

    /// Address of the staked Flow token.
    address public immutable S_FLOW_ADDRESS;

    /// Stake requests.
    mapping(uint256 => StakeRequest) public stakeRequests;

    /// Unstake requests.
    mapping(uint256 => UnstakeRequest) public unstakeRequests;

    /// Receipts
    mapping(uint256 => mapping(ReceiptType => uint256)) public receipts;

    /// Pending withdrawals.
    mapping(address => uint256) public pendingWithdrawals;

    /// Stake request IDs.
    uint256 public stakeRequestCount = 1;

    /// Unstake request IDs.
    uint256 public unstakeRequestCount = 1;

    /// sFlow to Flow rate, starting with 1 to 1.
    uint256 private _rate = 1 ether;

    modifier onlyRouterCOA() {
        if (msg.sender != ROUTER_COA) revert NotRouterCOA();
        _;
    }

    /// @notice FLOW (wei) implied by `sFlowWei` at the current `syncRate` (same convention as Cadence `flowPerSFlow`).
    function _flowFromSFlow(uint256 sFlowWei) private view returns (uint256) {
        return (sFlowWei * _rate) / 1e18;
    }

    /// @notice sFlow (wei) needed for `flowWei` at the current rate (inverse of `_flowFromSFlow`).
    function _sFlowFromFlow(uint256 flowWei) private view returns (uint256) {
        return (flowWei * 1e18) / _rate;
    }

    /// Deploy receipt to gain minter/burner rights.
    constructor(address _sFlowAddress, address _routerCOA) LSPVaultConfig(msg.sender) {
        ROUTER_COA = _routerCOA;
        S_FLOW_ADDRESS = _sFlowAddress;
        FLOW_RECEIPT = new FlowReceipt();
    }

    /// Accept FLOW sent by keeper (COA) for unstake fulfillment.
    receive() external payable {
        if (msg.sender != ROUTER_COA) revert NotRouterCOA();
    }

    /////////////////////////////////////////////////////////////////
    //                       user functions                        //
    /////////////////////////////////////////////////////////////////

    /**
     * Requests a stake of Flow to the LSP on cadence. Mints receipts tokens to the user.
     * @custom:throws StakingPaused if the staking is paused.
     * @custom:throws MinAmountStakeAmountTooLowNotMet if the amount is less than the minimum stake amount.
     */
    function requestStake() external payable returns (uint256) {
        if (_config.isStakingPaused) revert StakingPaused();
        if (msg.value < _config.minRequestAmount) revert OperationAmountTooLow(_config.minRequestAmount, msg.value);

        uint256 requestId = stakeRequestCount;

        uint256 expectedSFlow = _sFlowFromFlow(msg.value);
        
        uint256 afterSlippagePercentage;
        unchecked {
            afterSlippagePercentage = 1e18 - _config.slippageTolerance;
        }
        uint256 minAmountOut = expectedSFlow * afterSlippagePercentage / 1e18;

        stakeRequests[requestId] = StakeRequest({
            status: RequestStatus.QUEUED,
            user: msg.sender,
            amount: msg.value,
            minAmountOut: minAmountOut
        });

        FLOW_RECEIPT.mint(msg.sender, msg.value);
        receipts[requestId][ReceiptType.STAKE] = msg.value;

        emit StakeRequested(requestId, msg.sender, msg.value);

        unchecked {
            stakeRequestCount = requestId + 1;
        }

        return requestId;
    }

    /**
     * Withdraws the funds of a queued stake request.
     * @param _id id of the stake request.
     * @custom:throws InvalidRequest if the request is not queued.
     * @custom:throws NotRequestOwner if the request is not owned by the caller.
     */
    function cancelStakeRequest(uint256 _id) external {
        StakeRequest storage req = stakeRequests[_id];
        if (req.status != RequestStatus.QUEUED) revert InvalidRequest();
        if (msg.sender != req.user) revert NotRequestOwner();

        req.status = RequestStatus.CANCELLED;

        FLOW_RECEIPT.burn(req.user, receipts[_id][ReceiptType.STAKE]);

        pendingWithdrawals[req.user] += req.amount;

        emit StakeCancelled(_id, req.user, req.amount);
    }

    /**
     * Requests an unstake of sFlow. Locks sFlow in the vault for the keeper to bridge
     * to Cadence and process through the LSP.
     * @param _amount amount of sFlow to unstake.
     * @custom:throws MinAmountNotMet if the FLOW equivalent of `_amount` is below `minRequestAmount` (same FLOW floor as `requestStake`).
     */
    function requestUnstake(uint256 _amount) external returns (uint256) {
        uint256 flowEquivalent = _flowFromSFlow(_amount);
        if (flowEquivalent < _config.minRequestAmount) {
            revert OperationAmountTooLow(_config.minRequestAmount, flowEquivalent);
        }

        IERC20(S_FLOW_ADDRESS).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 requestId = unstakeRequestCount;

        FLOW_RECEIPT.mint(msg.sender, flowEquivalent);
        receipts[requestId][ReceiptType.UNSTAKE] = flowEquivalent;

        unstakeRequests[requestId] = UnstakeRequest({
            status: RequestStatus.QUEUED,
            user: msg.sender,
            amount: _amount,
            flowAmount: 0,
            unlockEpoch: 0
        });

        emit UnstakeRequested(requestId, msg.sender, _amount);

        unchecked {
            unstakeRequestCount = requestId + 1;
        }

        return requestId;
    }

    /**
     * Cancels an unstake request.
     * @param _id id of the unstake request.
     * @custom:throws InvalidRequest if the request is not queued.
     * @custom:throws NotRequestOwner if the request is not owned by the caller.
     */
    function cancelUnstakeRequest(uint256 _id) external {
        UnstakeRequest storage req = unstakeRequests[_id];
        // check if request is not already being processed
        if (req.status != RequestStatus.QUEUED) revert InvalidRequest();
        if (msg.sender != req.user) revert NotRequestOwner();

        req.status = RequestStatus.CANCELLED;

        FLOW_RECEIPT.burn(req.user, receipts[_id][ReceiptType.UNSTAKE]);

        IERC20(S_FLOW_ADDRESS).safeTransfer(req.user, req.amount);

        emit UnstakeCancelled(_id, req.user, req.amount);
    }

    /// Claims pending FLOW to `msg.sender` (EOAs and contracts with `receive()`).
    function claimPendingWithdrawal() external {
        _claimPendingWithdrawal(payable(msg.sender));
    }

    /**
     * Claims pending FLOW to `_recipient` (pull destination chosen by caller).
     * @dev Lets integrator contracts without `receive()` send FLOW to an EOA or payable contract.
     * @custom:throws InvalidRequest if the user has no pending withdrawal or `_recipient` is zero.
     * @custom:throws NativeTransferFailed if the transfer fails.
     */
    function claimPendingWithdrawal(address payable _recipient) external {
        _claimPendingWithdrawal(_recipient);
    }

    function _claimPendingWithdrawal(address payable _recipient) private {
        if (_recipient == address(0)) revert InvalidRequest();

        uint256 pendingWithdrawal = pendingWithdrawals[msg.sender];
        if (pendingWithdrawal == 0) revert InvalidRequest();

        pendingWithdrawals[msg.sender] = 0;

        (bool ok,) = _recipient.call{value: pendingWithdrawal}("");
        if (!ok) revert NativeTransferFailed();

        emit WithdrawalClaimed(msg.sender, _recipient, pendingWithdrawal);
    }

    /////////////////////////////////////////////////////////////////
    //                       ROUTER COA functions                  //
    /////////////////////////////////////////////////////////////////

    /// Restricted to COA function, which syncs sFlow/Flow rate on EVM side.
    function syncRate(uint256 _newRate) external onlyRouterCOA {
        if (_newRate == 0) revert InvalidRate();
        emit RateUpdated(_rate, _newRate);
        _rate = _newRate;
    }

    /**
     * Only valid in `AWAITING_FULFILLMENT` (after `withdrawPendingStakeNative`). Burns `amount` receipts.
     */
    function fulfillStakeRequest(uint256 _id, uint256 _sFlowAmount) external onlyRouterCOA {
        StakeRequest storage req = stakeRequests[_id];
        if (req.status != RequestStatus.AWAITING_FULFILLMENT) revert InvalidRequest();
        if (_sFlowAmount < req.minAmountOut) revert sFlowAmountTooLow(req.minAmountOut, _sFlowAmount);

        req.status = RequestStatus.FULFILLED;

        FLOW_RECEIPT.burn(req.user, receipts[_id][ReceiptType.STAKE]);
        IERC20(S_FLOW_ADDRESS).safeTransfer(req.user, _sFlowAmount);

        emit StakeFulfilled(_id, req.user, _sFlowAmount);
    }

    /**
     * @notice After `withdrawPendingStakeNative`, Cadence may refuse to stake if the implied sFlow is below `minAmountOut`.
     * @dev Refunds the full `req.amount` in native FLOW to the user. Burns stake receipts.
     */
    function cancelStakeRequestSlippage(uint256 _id) external payable onlyRouterCOA {
        StakeRequest storage req = stakeRequests[_id];
        if (req.status != RequestStatus.AWAITING_FULFILLMENT) revert InvalidRequest();

        uint256 refund = req.amount;
        if (msg.value != refund) revert SlippageCancelValueMismatch(refund, msg.value);

        req.status = RequestStatus.CANCELLED;

        FLOW_RECEIPT.burn(req.user, receipts[_id][ReceiptType.STAKE]);

        pendingWithdrawals[req.user] += refund;

        emit StakeCancelled(_id, req.user, refund);
    }

    /**
     * Restricted to COA. Marks untake as confirmed and fills expected unlock epoch and flow return amount.
     * @param _id id of the unstake request.
     * @param _flowAmount amount of the flow expected to be received in unlock epoch.
     * @param _unlockEpoch expected epoch when withdrawal unlocks for the request.
     */
    function confirmUnstakeRequest(uint256 _id, uint256 _flowAmount, uint256 _unlockEpoch) external onlyRouterCOA {
        UnstakeRequest storage req = unstakeRequests[_id];
        if (req.status != RequestStatus.AWAITING_FULFILLMENT) revert InvalidRequest();

        req.status = RequestStatus.UNSTAKE_CONFIRMED;
        req.flowAmount = _flowAmount;
        req.unlockEpoch = _unlockEpoch;

        emit UnstakeConfirmed(_id, req.user, _flowAmount, _unlockEpoch);
    }

    /**
     * Restricted to COA. Marks unstake as fulfilled and sends FLOW back to user.
     * Keeper passes the actual FLOW amount returned by the Cadence LSP.
     * @param _id id of the unstake request.
     */
    function fulfillUnstakeRequest(uint256 _id) external onlyRouterCOA {
        UnstakeRequest storage req = unstakeRequests[_id];

        if (req.status != RequestStatus.UNSTAKE_CONFIRMED) {
            revert InvalidRequest();
        }

        req.status = RequestStatus.FULFILLED;

        FLOW_RECEIPT.burn(req.user, receipts[_id][ReceiptType.UNSTAKE]);
        pendingWithdrawals[req.user] += req.flowAmount;

        emit UnstakeFulfilled(_id, req.user, req.flowAmount);
    }

    /// Pull native FLOW locked for a pending stake to the COA (`msg.sender`) for bridging to Cadence.
    function withdrawPendingStakeNative(uint256 _id) external onlyRouterCOA returns (uint256 amount) {
        StakeRequest storage req = stakeRequests[_id];
        if (req.status != RequestStatus.QUEUED) revert InvalidRequest();

        amount = req.amount;
        if (amount == 0) revert InvalidRequest();

        req.status = RequestStatus.AWAITING_FULFILLMENT;

        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    /// Pull locked sFlow for a pending unstake to the COA (`msg.sender`) for bridging to Cadence.
    function withdrawPendingUnstakeSFlow(uint256 _id) external onlyRouterCOA returns (uint256 amount) {
        UnstakeRequest storage req = unstakeRequests[_id];
        if (req.status != RequestStatus.QUEUED) revert InvalidRequest();

        req.status = RequestStatus.AWAITING_FULFILLMENT;

        amount = req.amount;
        IERC20(S_FLOW_ADDRESS).safeTransfer(msg.sender, amount);
    }

    /////////////////////////////////////////////////////////////////
    //                       view functions                        //
    /////////////////////////////////////////////////////////////////

    function getRate() external view returns (uint256) {
        return _rate;
    }

    /**
     * View-only quote: sFlow (wei) implied by a FLOW amount at the current rate (`getRate()`, same convention as Cadence `sFlowPerFlow` after `syncRate`).
     * @param flowWei FLOW input in wei (18 decimals).
     */
    function getSFlowQuote(uint256 flowWei) external view returns (uint256 sFlowWei) {
        return _sFlowFromFlow(flowWei);
    }

    /**
     * View-only quote: FLOW (wei) implied by an sFlow amount at the current rate (`getRate()`, same convention as Cadence `flowPerSFlow` after `syncRate`).
     * @param sFlowWei sFlow input in wei (18 decimals).
     */
    function getFlowQuote(uint256 sFlowWei) external view returns (uint256 flowWei) {
        return _flowFromSFlow(sFlowWei);
    }
}
