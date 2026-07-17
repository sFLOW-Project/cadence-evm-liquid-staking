// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILSPVaultConfig} from "./ILSPVaultConfig.sol";

interface ILSPVault is ILSPVaultConfig {
    // Structs
    enum RequestStatus {
        NONE,
        /// Funds for this id still in the vault (native for stake, sFlow for unstake); awaiting keeper.
        QUEUED,
        /// Funds are bridged to cadence side and request is awaiting fulfillment
        AWAITING_FULFILLMENT,
        UNSTAKE_CONFIRMED,
        FULFILLED,
        CANCELLED
    }

    enum ReceiptType {
        STAKE,
        UNSTAKE
    }

    struct StakeRequest {
        RequestStatus status;
        address user;
        // Flow amount
        uint256 amount;
        // Minimum sFlow amount after stake
        uint256 minAmountOut;
    }

    struct UnstakeRequest {
        RequestStatus status;
        address user;
        // sFlow amount
        uint256 amount;
        // Flow amount
        uint256 flowAmount;
        uint256 unlockEpoch;
    }

    // Errors
    error OperationAmountTooLow(uint256 minAmount, uint256 amount);
    error StakingPaused();
    error InvalidRequest();
    error NativeTransferFailed();
    error NotRouterCOA();
    error SlippageCancelValueMismatch(uint256 maxRefund, uint256 refund);
    error sFlowAmountTooLow(uint256 minAmountOut, uint256 sFlowAmount);
    error InvalidRouterCOA();
    error InvalidSFlowAddress();

    // Events
    event StakeRequested(uint256 indexed id, address indexed user, uint256 amount);
    event StakeCancelled(uint256 indexed id, address indexed user, uint256 refundWei, uint256 lockedAmountWei);
    event StakeFulfilled(uint256 indexed id, address indexed user, uint256 sFlowAmount);
    event UnstakeRequested(uint256 indexed id, address indexed user, uint256 amount);
    event UnstakeConfirmed(uint256 indexed id, address indexed user, uint256 flowAmount, uint256 unlockEpoch);
    event UnstakeFulfilled(uint256 indexed id, address indexed user, uint256 amount);
    event WithdrawalClaimed(address indexed user, address indexed recipient, uint256 amount);
    event RateUpdated(uint256 oldRate, uint256 newRate);

    // Functions
    function requestStake() external payable returns (uint256);
    function requestUnstake(uint256 _amount) external returns (uint256);
    function fulfillStakeRequest(uint256 _id, uint256 _sFlowAmount) external;
    function fulfillUnstakeRequest(uint256 _id) external;
    function withdrawPendingStakeNative(uint256 _id) external returns (uint256 amount);
    function cancelStakeRequestSlippage(uint256 _id) external payable;
    function withdrawPendingUnstakeSFlow(uint256 _id) external returns (uint256 amount);
    function syncRate(uint256 _newRate) external;
    function getRate() external view returns (uint256);
    function getSFlowQuote(uint256 flowWei) external view returns (uint256 sFlowWei);
    function getFlowQuote(uint256 sFlowWei) external view returns (uint256 flowWei);
    function claimPendingWithdrawal() external;
    function claimPendingWithdrawal(address payable _recipient) external;
}
