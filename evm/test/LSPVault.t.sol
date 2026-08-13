// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LSPVault} from "../src/LSPVault.sol";
import {FlowReceipt} from "../src/FlowReceipt.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ILSPVault} from "../src/interfaces/ILSPVault.sol";
import {ILSPVaultConfig} from "../src/interfaces/ILSPVaultConfig.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LSPVaultTest is Test {
    LSPVault public lspVault;
    FlowReceipt public flowReceipt;
    MockERC20 public sFlow;
    address public adminCOA = address(0x1);
    address public routerCOA = address(0x2);
    address public staker = address(0x3);

    uint256 internal constant MIN_REQUEST_AMOUNT = 0.01 ether;

    function setUp() public {
        sFlow = new MockERC20();
        // for simplicity used admin coa to deploy vault
        vm.prank(adminCOA);
        lspVault = new LSPVault(address(sFlow), routerCOA, MIN_REQUEST_AMOUNT);
        flowReceipt = FlowReceipt(lspVault.FLOW_RECEIPT());

        vm.deal(adminCOA, 10_000 ether);
        vm.deal(staker, 10_000 ether);
        vm.deal(routerCOA, 10_000 ether);

        vm.prank(adminCOA);
        lspVault.updateConfig(
            ILSPVaultConfig.Config({
                minRequestAmount: 0.01 ether, isStakingPaused: false, protocolFee: 0, slippageTolerance: 1e16
            })
        );

        vm.prank(routerCOA);
        lspVault.syncRate(1 ether);
    }

    function _stakeRequestId(address user, uint256 nonce) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(keccak256("LSPVault.stakeRequest"), user, nonce)));
    }

    function _unstakeRequestId(address user, uint256 nonce) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(keccak256("LSPVault.unstakeRequest"), user, nonce)));
    }

    function _warpPastCancelTimelock() internal {
        vm.warp(block.timestamp + lspVault.CANCEL_REQUEST_TIMELOCK());
    }

    function testRequestStakeRevertsIfStakingIsPaused() public {
        vm.prank(adminCOA);
        lspVault.updateConfig(
            ILSPVaultConfig.Config({
                minRequestAmount: 0.01 ether, isStakingPaused: true, protocolFee: 0, slippageTolerance: 1e16
            })
        );
        vm.prank(staker);
        vm.expectRevert(ILSPVault.StakingPaused.selector);
        lspVault.requestStake{value: 0.1 ether}();
    }

    function testRequestStakeRevertsIfAmountIsLessThanMinStakeAmount() public {
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.OperationAmountTooLow.selector, 0.01 ether, 0.009 ether));
        lspVault.requestStake{value: 0.009 ether}();
    }

    function testRequestStakeRevertsIfAmountNotCadenceRepresentable() public {
        uint256 dusty = MIN_REQUEST_AMOUNT + 1;
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.AmountNotCadenceRepresentable.selector, dusty));
        lspVault.requestStake{value: dusty}();
    }

    function testRequestUnstakeRevertsIfAmountNotCadenceRepresentable() public {
        uint256 dusty = MIN_REQUEST_AMOUNT + 1;
        sFlow.mint(staker, dusty);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), dusty);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.AmountNotCadenceRepresentable.selector, dusty));
        lspVault.requestUnstake(dusty);
        vm.stopPrank();
    }

    function testRequestUnstakeRevertsIfAmountIsLessThanMinRequestAmount() public {
        sFlow.mint(staker, 0.005 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 0.005 ether);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.OperationAmountTooLow.selector, 0.01 ether, 0.005 ether));
        lspVault.requestUnstake(0.005 ether);
        vm.stopPrank();
    }

    function testRequestUnstakeSucceedsWhenSFlowSmallButFlowEquivalentMeetsMin() public {
        vm.prank(routerCOA);
        lspVault.syncRate(2 ether);

        sFlow.mint(staker, 0.005 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 0.005 ether);
        lspVault.requestUnstake(0.005 ether);
        vm.stopPrank();

        assertEq(sFlow.balanceOf(address(lspVault)), 0.005 ether);
    }

    function testRequestUnstakeRevertsWhenFlowEquivalentBelowMinWithRateAboveOne() public {
        vm.prank(routerCOA);
        lspVault.syncRate(2 ether);

        sFlow.mint(staker, 0.004 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 0.004 ether);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.OperationAmountTooLow.selector, 0.01 ether, 0.008 ether));
        lspVault.requestUnstake(0.004 ether);
        vm.stopPrank();
    }

    function testFulfillStakeRequestRevertsIfRequestIsNotPending() public {
        vm.prank(routerCOA);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.fulfillStakeRequest(1, 0);
    }

    function testFulfillUnstakeRequestRevertsIfRequestIsNotPending() public {
        vm.prank(routerCOA);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.fulfillUnstakeRequest{value: 0}(1);
    }

    function testRequestStake() public {
        vm.prank(staker);
        lspVault.requestStake{value: 1000 ether}();
        assertEq(flowReceipt.balanceOf(staker), 1000e18);
        assertEq(address(lspVault).balance, 1000 ether);
    }

    function testCancelStakeRequest_creditsUserAndEmits() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 25 ether}();

        uint256 stakerBefore = staker.balance;

        vm.expectEmit(true, true, false, true);
        emit ILSPVault.StakeCancelled(reqId, staker, 25 ether);

        _warpPastCancelTimelock();
        vm.prank(staker);
        lspVault.cancelStakeRequest(reqId);

        assertEq(flowReceipt.balanceOf(staker), 0);
        assertEq(lspVault.pendingWithdrawals(staker), 25 ether);

        (ILSPVault.RequestStatus status,,,,) = lspVault.stakeRequests(reqId);
        assertEq(uint256(status), uint256(ILSPVault.RequestStatus.CANCELLED));

        vm.prank(staker);
        lspVault.claimPendingWithdrawal();
        assertEq(staker.balance, stakerBefore + 25 ether);
        assertEq(lspVault.pendingWithdrawals(staker), 0);
    }

    function testCancelStakeRequest_succeedsAfterTimelock() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 10 ether}();

        _warpPastCancelTimelock();
        vm.prank(staker);
        lspVault.cancelStakeRequest(reqId);

        assertEq(lspVault.pendingWithdrawals(staker), 10 ether);
    }

    function testCancelStakeRequest_revertsIfTimelockNotElapsed() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 10 ether}();

        vm.prank(staker);
        vm.expectRevert(ILSPVault.CantCancelRequestYet.selector);
        lspVault.cancelStakeRequest(reqId);

        _warpPastCancelTimelock();
        vm.prank(staker);
        lspVault.cancelStakeRequest(reqId);

        assertEq(lspVault.pendingWithdrawals(staker), 10 ether);
    }

    function testCancelStakeRequest_revertsIfNotOwner() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 10 ether}();

        vm.prank(routerCOA);
        vm.expectRevert(ILSPVault.NotRequestOwner.selector);
        lspVault.cancelStakeRequest(reqId);
    }

    function testCancelStakeRequest_revertsIfNotQueued() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 10 ether}();

        vm.prank(routerCOA);
        lspVault.withdrawPendingStakeNative(reqId);

        vm.prank(staker);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.cancelStakeRequest(reqId);
    }

    function testCancelStakeRequest_revertsIfAlreadyCancelled() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 10 ether}();

        _warpPastCancelTimelock();
        vm.prank(staker);
        lspVault.cancelStakeRequest(reqId);

        vm.prank(staker);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.cancelStakeRequest(reqId);
    }

    function testCancelStakeRequest_revertsIfUnknownRequestId() public {
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.cancelStakeRequest(999);
    }

    function testRequestUnstake() public {
        sFlow.mint(staker, 100 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 100 ether);
        lspVault.requestUnstake(100 ether);
        vm.stopPrank();

        assertEq(sFlow.balanceOf(address(lspVault)), 100 ether);
        assertEq(sFlow.balanceOf(staker), 0);
    }

    function testCancelUnstakeRequest_returnsSFlowAndEmits() public {
        sFlow.mint(staker, 50 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 50 ether);
        uint256 reqId = lspVault.requestUnstake(50 ether);
        vm.stopPrank();

        vm.expectEmit(true, true, false, true);
        emit ILSPVault.UnstakeCancelled(reqId, staker, 50 ether);

        _warpPastCancelTimelock();
        vm.prank(staker);
        lspVault.cancelUnstakeRequest(reqId);

        assertEq(flowReceipt.balanceOf(staker), 0);
        assertEq(sFlow.balanceOf(staker), 50 ether);
        assertEq(sFlow.balanceOf(address(lspVault)), 0);

        (ILSPVault.RequestStatus status,,,,,) = lspVault.unstakeRequests(reqId);
        assertEq(uint256(status), uint256(ILSPVault.RequestStatus.CANCELLED));
    }

    function testCancelUnstakeRequest_succeedsAfterTimelock() public {
        sFlow.mint(staker, 20 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 20 ether);
        uint256 reqId = lspVault.requestUnstake(20 ether);
        vm.stopPrank();

        _warpPastCancelTimelock();
        vm.prank(staker);
        lspVault.cancelUnstakeRequest(reqId);

        assertEq(sFlow.balanceOf(staker), 20 ether);
        assertEq(sFlow.balanceOf(address(lspVault)), 0);
    }

    function testCancelUnstakeRequest_revertsIfTimelockNotElapsed() public {
        sFlow.mint(staker, 10 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 10 ether);
        uint256 reqId = lspVault.requestUnstake(10 ether);
        vm.stopPrank();

        vm.prank(staker);
        vm.expectRevert(ILSPVault.CantCancelRequestYet.selector);
        lspVault.cancelUnstakeRequest(reqId);

        _warpPastCancelTimelock();
        vm.prank(staker);
        lspVault.cancelUnstakeRequest(reqId);

        assertEq(sFlow.balanceOf(staker), 10 ether);
        assertEq(sFlow.balanceOf(address(lspVault)), 0);
    }

    function testCancelUnstakeRequest_revertsIfNotOwner() public {
        sFlow.mint(staker, 10 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 10 ether);
        uint256 reqId = lspVault.requestUnstake(10 ether);
        vm.stopPrank();

        vm.prank(routerCOA);
        vm.expectRevert(ILSPVault.NotRequestOwner.selector);
        lspVault.cancelUnstakeRequest(reqId);
    }

    function testCancelUnstakeRequest_revertsIfNotQueued() public {
        sFlow.mint(staker, 10 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 10 ether);
        uint256 reqId = lspVault.requestUnstake(10 ether);
        vm.stopPrank();

        vm.prank(routerCOA);
        lspVault.withdrawPendingUnstakeSFlow(reqId);

        vm.prank(staker);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.cancelUnstakeRequest(reqId);
    }

    function testCancelUnstakeRequest_revertsIfAlreadyCancelled() public {
        sFlow.mint(staker, 10 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 10 ether);
        uint256 reqId = lspVault.requestUnstake(10 ether);
        vm.stopPrank();

        _warpPastCancelTimelock();
        vm.prank(staker);
        lspVault.cancelUnstakeRequest(reqId);

        vm.prank(staker);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.cancelUnstakeRequest(reqId);
    }

    function testCancelUnstakeRequest_revertsIfUnknownRequestId() public {
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.cancelUnstakeRequest(999);
    }

    function testCancelUnstakeRequest_burnsFlowDenominatedReceiptWhenRateAboveOne() public {
        vm.prank(routerCOA);
        lspVault.syncRate(2 ether);

        sFlow.mint(staker, 10 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 10 ether);
        uint256 reqId = lspVault.requestUnstake(10 ether);
        vm.stopPrank();

        assertEq(flowReceipt.balanceOf(staker), 20 ether);

        _warpPastCancelTimelock();
        vm.prank(staker);
        lspVault.cancelUnstakeRequest(reqId);

        assertEq(flowReceipt.balanceOf(staker), 0);
        assertEq(sFlow.balanceOf(staker), 10 ether);
    }

    function testFulfillStakeRequest() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 100 ether}();

        // COA bridges sFlow into the vault, then fulfills
        sFlow.mint(address(lspVault), 100 ether);
        vm.startPrank(routerCOA);
        lspVault.withdrawPendingStakeNative(reqId);
        lspVault.fulfillStakeRequest(reqId, 100 ether);
        vm.stopPrank();

        assertEq(sFlow.balanceOf(staker), 100 ether);
        assertEq(flowReceipt.balanceOf(staker), 0);
    }

    function testFulfillUnstakeRequest() public {
        sFlow.mint(staker, 100 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 100 ether);
        uint256 reqId = lspVault.requestUnstake(100 ether);
        vm.stopPrank();

        vm.prank(routerCOA);
        lspVault.withdrawPendingUnstakeSFlow(reqId);

        vm.prank(routerCOA);
        lspVault.confirmUnstakeRequest(reqId, 100 ether, 1);

        // COA sends FLOW with fulfill; user pulls via claimPendingWithdrawal
        uint256 balBefore = staker.balance;
        vm.prank(routerCOA);
        lspVault.fulfillUnstakeRequest{value: 100 ether}(reqId);

        vm.prank(staker);
        lspVault.claimPendingWithdrawal();

        assertEq(staker.balance, balBefore + 100 ether);
    }

    function testUpdateConfig() public {
        vm.prank(adminCOA);
        lspVault.updateConfig(
            ILSPVaultConfig.Config({
                minRequestAmount: 0.01 ether, isStakingPaused: true, protocolFee: 0, slippageTolerance: 1e16
            })
        );
        assertEq(lspVault.getConfig().isStakingPaused, true);
        assertEq(lspVault.getConfig().protocolFee, 0);
        assertEq(lspVault.getConfig().minRequestAmount, 0.01 ether);
    }

    function testUpdateConfig_acceptsMaxProtocolFee() public {
        vm.prank(adminCOA);
        lspVault.updateConfig(
            ILSPVaultConfig.Config({
                minRequestAmount: 0.01 ether, isStakingPaused: false, protocolFee: 2e17, slippageTolerance: 1e16
            })
        );
        assertEq(lspVault.getConfig().protocolFee, 2e17);
    }

    function testUpdateConfig_revertsIfProtocolFeeExceedsMax() public {
        vm.prank(adminCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVaultConfig.ProtocolFeeTooHigh.selector, 2e17, 2e17 + 1));
        lspVault.updateConfig(
            ILSPVaultConfig.Config({
                minRequestAmount: 0.01 ether, isStakingPaused: false, protocolFee: 2e17 + 1, slippageTolerance: 1e16
            })
        );
    }

    function testSetMinRequestAmount() public {
        vm.prank(adminCOA);
        vm.expectEmit(true, true, false, true);
        emit ILSPVaultConfig.MinRequestAmountUpdated(0.01 ether, 0.02 ether);
        lspVault.setMinRequestAmount(0.02 ether);
        assertEq(lspVault.getConfig().minRequestAmount, 0.02 ether);
    }

    function testMinRequestAmountInitializedOnDeploy_stakeEnforcesItImmediately() public {
        vm.prank(adminCOA);
        LSPVault freshVault = new LSPVault(address(sFlow), routerCOA, MIN_REQUEST_AMOUNT);

        assertEq(freshVault.getConfig().minRequestAmount, MIN_REQUEST_AMOUNT);

        vm.prank(routerCOA);
        freshVault.syncRate(1 ether);

        vm.prank(staker);
        vm.expectRevert(
            abi.encodeWithSelector(ILSPVault.OperationAmountTooLow.selector, MIN_REQUEST_AMOUNT, 0.009 ether)
        );
        freshVault.requestStake{value: 0.009 ether}();
    }

    function testConstructor_revertsIfMinRequestAmountIsZero() public {
        vm.prank(adminCOA);
        vm.expectRevert(ILSPVaultConfig.MinRequestAmountMustBePositive.selector);
        new LSPVault(address(sFlow), routerCOA, 0);
    }

    function testConstructor_revertsIfMinRequestAmountNotCadenceRepresentable() public {
        uint256 dusty = MIN_REQUEST_AMOUNT + 1;
        vm.prank(adminCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVaultConfig.MinRequestAmountNotCadenceRepresentable.selector, dusty));
        new LSPVault(address(sFlow), routerCOA, dusty);
    }

    function testConstructor_acceptsSmallestCadenceUlp() public {
        uint256 smallest = 1e10;
        vm.prank(adminCOA);
        LSPVault freshVault = new LSPVault(address(sFlow), routerCOA, smallest);
        assertEq(freshVault.getConfig().minRequestAmount, smallest);
    }

    function testSetMinRequestAmount_revertsIfZero() public {
        vm.prank(adminCOA);
        vm.expectRevert(ILSPVaultConfig.MinRequestAmountMustBePositive.selector);
        lspVault.setMinRequestAmount(0);
    }

    function testSetMinRequestAmount_revertsIfNotCadenceRepresentable() public {
        uint256 dusty = MIN_REQUEST_AMOUNT + 1;
        vm.prank(adminCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVaultConfig.MinRequestAmountNotCadenceRepresentable.selector, dusty));
        lspVault.setMinRequestAmount(dusty);
    }

    function testUpdateConfig_revertsIfMinRequestAmountIsZero() public {
        vm.prank(adminCOA);
        vm.expectRevert(ILSPVaultConfig.MinRequestAmountMustBePositive.selector);
        lspVault.updateConfig(
            ILSPVaultConfig.Config({
                minRequestAmount: 0, isStakingPaused: false, protocolFee: 0, slippageTolerance: 1e16
            })
        );
    }

    function testUpdateConfig_revertsIfMinRequestAmountNotCadenceRepresentable() public {
        uint256 dusty = MIN_REQUEST_AMOUNT + 1;
        vm.prank(adminCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVaultConfig.MinRequestAmountNotCadenceRepresentable.selector, dusty));
        lspVault.updateConfig(
            ILSPVaultConfig.Config({
                minRequestAmount: dusty, isStakingPaused: false, protocolFee: 0, slippageTolerance: 1e16
            })
        );
    }

    function testSetIsStakingPaused() public {
        vm.prank(adminCOA);
        vm.expectEmit(true, true, false, true);
        emit ILSPVaultConfig.IsStakingPausedUpdated(false, true);
        lspVault.setIsStakingPaused(true);
        assertEq(lspVault.getConfig().isStakingPaused, true);
    }

    function testSetProtocolFee() public {
        vm.prank(adminCOA);
        vm.expectEmit(true, true, false, true);
        emit ILSPVaultConfig.ProtocolFeeUpdated(0, 0.01 ether);
        lspVault.setProtocolFee(0.01 ether);
        assertEq(lspVault.getConfig().protocolFee, 0.01 ether);
    }

    function testSetProtocolFee_acceptsMaxTwentyPercent() public {
        vm.prank(adminCOA);
        vm.expectEmit(true, true, false, true);
        emit ILSPVaultConfig.ProtocolFeeUpdated(0, 2e17);
        lspVault.setProtocolFee(2e17);
        assertEq(lspVault.getConfig().protocolFee, 2e17);
    }

    function testSetProtocolFee_revertsIfExceedsMax() public {
        vm.prank(adminCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVaultConfig.ProtocolFeeTooHigh.selector, 2e17, 2e17 + 1));
        lspVault.setProtocolFee(2e17 + 1);
    }

    function testSetSlippageTolerance() public {
        vm.prank(adminCOA);
        vm.expectEmit(true, true, false, true);
        emit ILSPVaultConfig.SlippageToleranceUpdated(1e16, 0);
        lspVault.setSlippageTolerance(0);
        assertEq(lspVault.getConfig().slippageTolerance, 0);
    }

    function testSetSlippageTolerance_acceptsMaxOnePercent() public {
        vm.prank(adminCOA);
        lspVault.setSlippageTolerance(0);
        vm.prank(adminCOA);
        vm.expectEmit(true, true, false, true);
        emit ILSPVaultConfig.SlippageToleranceUpdated(0, 1e16);
        lspVault.setSlippageTolerance(1e16);
        assertEq(lspVault.getConfig().slippageTolerance, 1e16);
    }

    function testSetSlippageTolerance_revertsIfExceedsMax() public {
        vm.prank(adminCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVaultConfig.SlippageToleranceTooHigh.selector, 1e16, 1e16 + 1));
        lspVault.setSlippageTolerance(1e16 + 1);
    }

    /// Constructor sets 1% slippage; stake enforces it without an explicit `updateConfig` / `setSlippageTolerance`.
    function testSlippageToleranceInitializedOnDeploy_stakeUsesItImmediately() public {
        vm.prank(adminCOA);
        LSPVault freshVault = new LSPVault(address(sFlow), routerCOA, MIN_REQUEST_AMOUNT);

        assertEq(freshVault.getConfig().slippageTolerance, 1e16, "default slippage after deploy");
        assertEq(freshVault.getConfig().minRequestAmount, MIN_REQUEST_AMOUNT, "min set atomically on deploy");

        vm.prank(routerCOA);
        freshVault.syncRate(1 ether);

        uint256 stakeAmount = 100 ether;
        vm.prank(staker);
        uint256 reqId = freshVault.requestStake{value: stakeAmount}();

        vm.prank(routerCOA);
        freshVault.withdrawPendingStakeNative(reqId);

        (,,, uint256 minAmountOut,) = freshVault.stakeRequests(reqId);
        assertEq(minAmountOut, stakeAmount * (1e18 - 1e16) / 1e18, "minAmountOut from default slippage");

        sFlow.mint(address(freshVault), minAmountOut);
        vm.prank(routerCOA);
        freshVault.fulfillStakeRequest(reqId, minAmountOut);

        assertEq(sFlow.balanceOf(staker), minAmountOut);
    }

    function testSyncRate() public {
        vm.prank(routerCOA);
        lspVault.syncRate(2 ether);
        assertEq(lspVault.getRate(), 2 ether);
    }

    /// Plain ETH transfer triggers `receive`; only `ROUTER_COA` may fund the vault this way (e.g. unstake FLOW returns).
    function testReceive_acceptsNativeFromRouterCOA() public {
        uint256 vaultBefore = address(lspVault).balance;
        vm.prank(routerCOA);
        (bool ok,) = address(lspVault).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(address(lspVault).balance, vaultBefore + 2 ether);
    }

    function testReceive_revertsIfNotRouterCOA() public {
        vm.prank(staker);
        (bool ok, bytes memory ret) = address(lspVault).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(ret), ILSPVault.NotRouterCOA.selector);
    }

    function testGetFlowQuoteAndGetSFlowQuote() public {
        assertEq(lspVault.getFlowQuote(1 ether), 1 ether);
        assertEq(lspVault.getSFlowQuote(1 ether), 1 ether);

        vm.prank(routerCOA);
        lspVault.syncRate(2 ether);

        assertEq(lspVault.getFlowQuote(1 ether), 2 ether);
        assertEq(lspVault.getSFlowQuote(2 ether), 1 ether);
    }

    function testUpdateConfigRevertsIfNotOwner() public {
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, staker));
        lspVault.updateConfig(
            ILSPVaultConfig.Config({
                minRequestAmount: 0.01 ether, isStakingPaused: true, protocolFee: 0, slippageTolerance: 1e16
            })
        );
    }

    function testSyncRateRevertsIfNotOwner() public {
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.NotRouterCOA.selector));
        lspVault.syncRate(2 ether);
    }

    function testSyncRate_revertsIfZeroRate() public {
        assertEq(lspVault.getRate(), 1 ether);

        vm.prank(routerCOA);
        vm.expectRevert(ILSPVault.InvalidRate.selector);
        lspVault.syncRate(0);

        assertEq(lspVault.getRate(), 1 ether);
    }

    function testConfirmUnstakeRequestRevertsIfNotOwner() public {
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.NotRouterCOA.selector));
        lspVault.confirmUnstakeRequest(1, 100 ether, 1);
    }

    function testConfirmUnstakeRequestRevertsIfRequestIsNotAwaitingFulfillment() public {
        vm.prank(routerCOA);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.confirmUnstakeRequest(1, 100 ether, 1);
    }

    function testFulfillUnstakeRequest_revertsIfValueDoesNotMatchConfirmed() public {
        sFlow.mint(staker, 100 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 100 ether);
        lspVault.requestUnstake(100 ether);
        vm.stopPrank();

        uint256 reqId = _unstakeRequestId(staker, 0);

        vm.prank(routerCOA);
        lspVault.withdrawPendingUnstakeSFlow(reqId);

        vm.prank(routerCOA);
        lspVault.confirmUnstakeRequest(reqId, 100 ether, 1);

        vm.prank(routerCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.UnstakeFulfillmentAmountInvalid.selector, 100 ether, 99 ether));
        lspVault.fulfillUnstakeRequest{value: 99 ether}(reqId);
    }

    function testClaimPendingWithdrawal_revertsIfNothingPending() public {
        vm.prank(staker);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.claimPendingWithdrawal();
    }

    function testClaimPendingWithdrawal_contractWithoutReceive_claimsToRecipient() public {
        address beneficiary = address(0x6);
        NoReceiveClaimer claimer = new NoReceiveClaimer(lspVault);

        vm.deal(address(claimer), 10 ether);
        claimer.stake{value: 10 ether}();
        uint256 reqId = _stakeRequestId(address(claimer), 0);

        vm.prank(routerCOA);
        lspVault.withdrawPendingStakeNative(reqId);

        vm.prank(routerCOA);
        lspVault.cancelStakeRequestSlippage{value: 10 ether}(reqId);

        assertEq(lspVault.pendingWithdrawals(address(claimer)), 10 ether);

        uint256 beneficiaryBefore = beneficiary.balance;
        claimer.claimTo(payable(beneficiary));

        assertEq(beneficiary.balance, beneficiaryBefore + 10 ether);
        assertEq(lspVault.pendingWithdrawals(address(claimer)), 0);
    }

    function testClaimPendingWithdrawal_noArgRevertsForContractWithoutReceive() public {
        NoReceiveClaimer claimer = new NoReceiveClaimer(lspVault);

        vm.deal(address(claimer), 10 ether);
        claimer.stake{value: 10 ether}();
        uint256 reqId = _stakeRequestId(address(claimer), 0);

        vm.prank(routerCOA);
        lspVault.withdrawPendingStakeNative(reqId);

        vm.prank(routerCOA);
        lspVault.cancelStakeRequestSlippage{value: 10 ether}(reqId);

        vm.prank(address(claimer));
        vm.expectRevert(ILSPVault.NativeTransferFailed.selector);
        lspVault.claimPendingWithdrawal();
    }

    function testClaimPendingWithdrawal_revertsIfRecipientIsZero() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 10 ether}();

        vm.prank(routerCOA);
        lspVault.withdrawPendingStakeNative(reqId);

        vm.prank(routerCOA);
        lspVault.cancelStakeRequestSlippage{value: 10 ether}(reqId);

        vm.prank(staker);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.claimPendingWithdrawal(payable(address(0)));
    }

    function testFulfillStakeRequest_revertsIfSFlowBelowMinAmountOut() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 100 ether}();

        sFlow.mint(address(lspVault), 100 ether);
        vm.prank(routerCOA);
        lspVault.withdrawPendingStakeNative(reqId);

        (,,, uint256 minAmountOut,) = lspVault.stakeRequests(reqId);

        vm.prank(routerCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.sFlowAmountTooLow.selector, minAmountOut, minAmountOut - 1));
        lspVault.fulfillStakeRequest(reqId, minAmountOut - 1);
    }

    function testWithdrawPendingStakeNative_movesWeiToOwner() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 50 ether}();

        uint256 routerCOABefore = routerCOA.balance;
        uint256 vaultBefore = address(lspVault).balance;

        vm.prank(routerCOA);
        uint256 withdrawn = lspVault.withdrawPendingStakeNative(reqId);

        assertEq(withdrawn, 50 ether);
        assertEq(routerCOA.balance, routerCOABefore + 50 ether, "routerCOA balance mismatch");
        assertEq(address(lspVault).balance, vaultBefore - 50 ether, "vault balance mismatch");

        (ILSPVault.RequestStatus status,, uint256 amount, uint256 minAmountOut,) = lspVault.stakeRequests(reqId);
        assertEq(uint256(status), uint256(ILSPVault.RequestStatus.AWAITING_FULFILLMENT), "status mismatch");
        assertEq(amount, 50 ether, "amount mismatch");
        // slippageTolerance 1e16 → min sFlow = flow * (1e18 - 1e16) / 1e18
        assertEq(minAmountOut, 50 ether * (1e18 - 1e16) / 1e18, "minAmountOut mismatch");
    }

    function testWithdrawPendingStakeNative_revertsIfNotQueued() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 10 ether}();

        vm.startPrank(routerCOA);
        lspVault.withdrawPendingStakeNative(reqId);

        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.withdrawPendingStakeNative(reqId);
        vm.stopPrank();
    }

    /// `amount == 0` is unreachable via `requestStake`; if corrupted in storage, withdraw sends 0 wei.
    function testWithdrawPendingStakeNative_withZeroAmountInStorage() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 10 ether}();

        // stakeRequests is mapping slot 5; zero out StakeRequest.amount (second word).
        bytes32 baseSlot = keccak256(abi.encode(reqId, uint256(5)));
        vm.store(address(lspVault), bytes32(uint256(baseSlot) + 1), bytes32(0));

        (,, uint256 amount,,) = lspVault.stakeRequests(reqId);
        assertEq(amount, 0);

        vm.prank(routerCOA);
        uint256 withdrawn = lspVault.withdrawPendingStakeNative(reqId);
        assertEq(withdrawn, 0);

        (ILSPVault.RequestStatus status,,,,) = lspVault.stakeRequests(reqId);
        assertEq(uint256(status), uint256(ILSPVault.RequestStatus.AWAITING_FULFILLMENT));
    }

    function testWithdrawPendingStakeNative_revertsIfNativeTransferFails() public {
        RevertingEthReceiver badRouter = new RevertingEthReceiver();

        vm.prank(adminCOA);
        LSPVault v = new LSPVault(address(sFlow), address(badRouter), MIN_REQUEST_AMOUNT);

        vm.prank(adminCOA);
        v.updateConfig(
            ILSPVaultConfig.Config({
                minRequestAmount: 0.01 ether, isStakingPaused: false, protocolFee: 0, slippageTolerance: 1e16
            })
        );

        vm.prank(address(badRouter));
        v.syncRate(1 ether);

        vm.prank(staker);
        uint256 reqId = v.requestStake{value: 5 ether}();

        vm.prank(address(badRouter));
        vm.expectRevert(ILSPVault.NativeTransferFailed.selector);
        v.withdrawPendingStakeNative(reqId);
    }

    function testCancelStakeRequestSlippage_refundsUserBurnsReceipts() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 42 ether}();

        vm.prank(routerCOA);
        lspVault.withdrawPendingStakeNative(reqId);

        assertEq(flowReceipt.balanceOf(staker), 42 ether);

        uint256 stakerBefore = staker.balance;

        vm.expectEmit(true, true, false, true);
        emit ILSPVault.StakeCancelled(reqId, staker, 42 ether);

        vm.prank(routerCOA);
        lspVault.cancelStakeRequestSlippage{value: 42 ether}(reqId);

        assertEq(lspVault.pendingWithdrawals(staker), 42 ether);
        vm.prank(staker);
        lspVault.claimPendingWithdrawal();
        assertEq(staker.balance, stakerBefore + 42 ether);
        assertEq(flowReceipt.balanceOf(staker), 0);

        (ILSPVault.RequestStatus status,,,,) = lspVault.stakeRequests(reqId);
        assertEq(uint256(status), uint256(ILSPVault.RequestStatus.CANCELLED));
    }

    /// Slippage cancel requires the router to return the full locked stake amount.
    function testCancelStakeRequestSlippage_revertsIfPartialRefund() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 10 ether}();

        vm.prank(routerCOA);
        lspVault.withdrawPendingStakeNative(reqId);

        vm.prank(routerCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.SlippageCancelValueMismatch.selector, 10 ether, 7 ether));
        lspVault.cancelStakeRequestSlippage{value: 7 ether}(reqId);
    }

    function testCancelStakeRequestSlippage_revertsIfRefundExceedsStake() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 10 ether}();

        vm.prank(routerCOA);
        lspVault.withdrawPendingStakeNative(reqId);

        vm.prank(routerCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.SlippageCancelValueMismatch.selector, 10 ether, 11 ether));
        lspVault.cancelStakeRequestSlippage{value: 11 ether}(reqId);
    }

    function testCancelStakeRequestSlippage_revertsIfZeroRefund() public {
        vm.prank(staker);
        uint256 reqId = lspVault.requestStake{value: 10 ether}();

        vm.prank(routerCOA);
        lspVault.withdrawPendingStakeNative(reqId);

        vm.prank(routerCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.SlippageCancelValueMismatch.selector, 10 ether, 0));
        lspVault.cancelStakeRequestSlippage{value: 0 ether}(reqId);
    }

    function testCancelStakeRequestSlippage_revertsIfNotAwaiting() public {
        vm.prank(staker);
        lspVault.requestStake{value: 10 ether}();

        vm.prank(routerCOA);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.cancelStakeRequestSlippage{value: 10 ether}(_stakeRequestId(staker, 0));
    }

    function testWithdrawPendingUnstakeSFlow_movesTokensToOwner() public {
        sFlow.mint(staker, 40 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), type(uint256).max);
        uint256 reqId = lspVault.requestUnstake(40 ether);
        vm.stopPrank();

        vm.prank(routerCOA);
        uint256 pulled = lspVault.withdrawPendingUnstakeSFlow(reqId);

        assertEq(pulled, 40 ether);
        assertEq(sFlow.balanceOf(routerCOA), 40 ether);
        assertEq(sFlow.balanceOf(address(lspVault)), 0);
    }

    function testKeeperUnstakeFullFlow() public {
        sFlow.mint(staker, 100 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 100 ether);
        uint256 reqId = lspVault.requestUnstake(100 ether);
        vm.stopPrank();

        assertEq(reqId, _unstakeRequestId(staker, 0));
        assertEq(sFlow.balanceOf(address(lspVault)), 100 ether);

        // Step 1: keeper withdraws sFlow for Cadence bridging.
        vm.prank(routerCOA);
        uint256 sFlowPulled = lspVault.withdrawPendingUnstakeSFlow(reqId);
        assertEq(sFlowPulled, 100 ether);
        assertEq(sFlow.balanceOf(routerCOA), 100 ether);
        assertEq(sFlow.balanceOf(address(lspVault)), 0);

        vm.prank(routerCOA);
        lspVault.confirmUnstakeRequest(reqId, 100 ether, 1);

        // Step 2: keeper fulfills with the FLOW returned from Cadence.
        uint256 userBefore = staker.balance;
        vm.prank(routerCOA);
        lspVault.fulfillUnstakeRequest{value: 100 ether}(reqId);

        vm.prank(staker);
        lspVault.claimPendingWithdrawal();

        assertEq(staker.balance, userBefore + 100 ether);
        assertEq(address(lspVault).balance, 0);

        (ILSPVault.RequestStatus status,,,,,) = lspVault.unstakeRequests(reqId);
        assertEq(uint256(status), uint256(ILSPVault.RequestStatus.FULFILLED));
    }

    /// Double withdrawal of sFlow must revert — status is no longer QUEUED after first call.
    function testWithdrawPendingUnstakeSFlow_revertsOnDoubleCall() public {
        sFlow.mint(staker, 50 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 50 ether);
        uint256 reqId = lspVault.requestUnstake(50 ether);
        vm.stopPrank();

        vm.startPrank(routerCOA);
        lspVault.withdrawPendingUnstakeSFlow(reqId);

        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.withdrawPendingUnstakeSFlow(reqId);
        vm.stopPrank();
    }

    /// fulfillUnstakeRequest must reject a QUEUED request (sFlow not yet withdrawn).
    function testFulfillUnstakeRequest_revertsIfSFlowNotWithdrawn() public {
        sFlow.mint(staker, 50 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 50 ether);
        uint256 reqId = lspVault.requestUnstake(50 ether);
        vm.stopPrank();

        vm.prank(routerCOA);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.fulfillUnstakeRequest{value: 50 ether}(reqId);
    }

    /// fulfillUnstakeRequest must reject a FULFILLED request (no double-pay).
    function testFulfillUnstakeRequest_revertsIfAlreadyFulfilled() public {
        sFlow.mint(staker, 50 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 50 ether);
        uint256 reqId = lspVault.requestUnstake(50 ether);
        vm.stopPrank();

        vm.prank(routerCOA);
        lspVault.withdrawPendingUnstakeSFlow(reqId);
        vm.prank(routerCOA);
        lspVault.confirmUnstakeRequest(reqId, 50 ether, 1);

        vm.startPrank(routerCOA);
        lspVault.fulfillUnstakeRequest{value: 50 ether}(reqId);

        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.fulfillUnstakeRequest{value: 50 ether}(reqId);
        vm.stopPrank();
    }

    /// Multiple sequential unstake requests each go through the full keeper flow.
    function testKeeperUnstakeMultipleRequests() public {
        address staker2 = address(0x4);
        sFlow.mint(staker, 60 ether);
        sFlow.mint(staker2, 40 ether);

        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 60 ether);
        uint256 reqId1 = lspVault.requestUnstake(60 ether);
        vm.stopPrank();

        vm.startPrank(staker2);
        sFlow.approve(address(lspVault), 40 ether);
        uint256 reqId2 = lspVault.requestUnstake(40 ether);
        vm.stopPrank();

        // Keeper processes both in sequence (each user has their own per-user id).
        vm.startPrank(routerCOA);
        lspVault.withdrawPendingUnstakeSFlow(reqId1);
        lspVault.withdrawPendingUnstakeSFlow(reqId2);
        lspVault.confirmUnstakeRequest(reqId1, 60 ether, 1);
        lspVault.confirmUnstakeRequest(reqId2, 40 ether, 1);
        vm.stopPrank();

        uint256 bal1Before = staker.balance;
        uint256 bal2Before = staker2.balance;

        vm.startPrank(routerCOA);
        lspVault.fulfillUnstakeRequest{value: 60 ether}(reqId1);
        lspVault.fulfillUnstakeRequest{value: 40 ether}(reqId2);
        vm.stopPrank();

        vm.prank(staker);
        lspVault.claimPendingWithdrawal();
        vm.prank(staker2);
        lspVault.claimPendingWithdrawal();

        assertEq(staker.balance, bal1Before + 60 ether);
        assertEq(staker2.balance, bal2Before + 40 ether);
        assertEq(address(lspVault).balance, 0);
    }

    function testFulfillUnstakeRequestPartial_creditsReturnedAmount() public {
        sFlow.mint(staker, 100 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 100 ether);
        uint256 reqId = lspVault.requestUnstake(100 ether);
        vm.stopPrank();

        vm.prank(routerCOA);
        lspVault.withdrawPendingUnstakeSFlow(reqId);
        vm.prank(routerCOA);
        lspVault.confirmUnstakeRequest(reqId, 100 ether, 1);

        uint256 returned = 40 ether;
        vm.expectEmit(true, true, false, true);
        emit ILSPVault.UnstakeFulfilled(reqId, staker, returned);

        vm.prank(routerCOA);
        lspVault.fulfillUnstakeRequestPartial{value: returned}(reqId);

        assertEq(lspVault.pendingWithdrawals(staker), returned);
        assertEq(flowReceipt.balanceOf(staker), 0);
        assertEq(address(lspVault).balance, returned);

        (ILSPVault.RequestStatus status,,, uint256 flowAmount,,) = lspVault.unstakeRequests(reqId);
        assertEq(uint256(status), uint256(ILSPVault.RequestStatus.FULFILLED));
        assertEq(flowAmount, returned);

        uint256 userBefore = staker.balance;
        vm.prank(staker);
        lspVault.claimPendingWithdrawal();
        assertEq(staker.balance, userBefore + returned);
        assertEq(address(lspVault).balance, 0);
    }

    function testFulfillUnstakeRequestPartial_revertsIfZeroOrAboveConfirmed() public {
        sFlow.mint(staker, 50 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 50 ether);
        uint256 reqId = lspVault.requestUnstake(50 ether);
        vm.stopPrank();

        vm.prank(routerCOA);
        lspVault.withdrawPendingUnstakeSFlow(reqId);
        vm.prank(routerCOA);
        lspVault.confirmUnstakeRequest(reqId, 50 ether, 1);

        vm.prank(routerCOA);
        vm.expectRevert(abi.encodeWithSelector(ILSPVault.UnstakeFulfillmentAmountInvalid.selector, 50 ether, 0));
        lspVault.fulfillUnstakeRequestPartial{value: 0}(reqId);

        vm.prank(routerCOA);
        vm.expectRevert(
            abi.encodeWithSelector(ILSPVault.UnstakeFulfillmentAmountInvalid.selector, 50 ether, 50 ether + 1)
        );
        lspVault.fulfillUnstakeRequestPartial{value: 50 ether + 1}(reqId);
    }

    function testFulfillUnstakeRequestPartial_revertsIfNotConfirmed() public {
        sFlow.mint(staker, 50 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 50 ether);
        uint256 reqId = lspVault.requestUnstake(50 ether);
        vm.stopPrank();

        vm.prank(routerCOA);
        vm.expectRevert(ILSPVault.InvalidRequest.selector);
        lspVault.fulfillUnstakeRequestPartial{value: 10 ether}(reqId);
    }

    function testFulfillUnstakeRequestPartial_allowsFullConfirmedAmount() public {
        sFlow.mint(staker, 50 ether);
        vm.startPrank(staker);
        sFlow.approve(address(lspVault), 50 ether);
        uint256 reqId = lspVault.requestUnstake(50 ether);
        vm.stopPrank();

        vm.prank(routerCOA);
        lspVault.withdrawPendingUnstakeSFlow(reqId);
        vm.prank(routerCOA);
        lspVault.confirmUnstakeRequest(reqId, 50 ether, 1);

        vm.prank(routerCOA);
        lspVault.fulfillUnstakeRequestPartial{value: 50 ether}(reqId);

        assertEq(lspVault.pendingWithdrawals(staker), 50 ether);
    }

    function testStakeAndUnstakeRequestIds_useDistinctDomains() public {
        assertTrue(_stakeRequestId(staker, 0) != _unstakeRequestId(staker, 0));
    }
}

/// Integrator-style contract with no `receive()`; claims via explicit recipient.
contract NoReceiveClaimer {
    LSPVault public immutable vault;

    constructor(LSPVault _vault) {
        vault = _vault;
    }

    function stake() external payable {
        vault.requestStake{value: msg.value}();
    }

    function claimTo(address payable recipient) external {
        vault.claimPendingWithdrawal(recipient);
    }
}

/// COA stand-in that rejects native payouts from `LSPVault.withdrawPendingStakeNative`.
contract RevertingEthReceiver {
    receive() external payable {
        revert();
    }
}
