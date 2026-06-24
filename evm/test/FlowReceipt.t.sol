// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FlowReceipt} from "../src/FlowReceipt.sol";
import {IFlowReceipt} from "../src/interfaces/IFlowReceipt.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FlowReceiptTest is Test {
    FlowReceipt public receipt;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        receipt = new FlowReceipt();
    }

    function testConstructor_MetaAndOwner() public view {
        assertEq(receipt.name(), "sFlow Receipt");
        assertEq(receipt.symbol(), "sFR");
        assertEq(receipt.owner(), address(this));
    }

    function testMint_IncreasesBalanceAndSupply() public {
        receipt.mint(alice, 100e18);
        assertEq(receipt.balanceOf(alice), 100e18);
        assertEq(receipt.totalSupply(), 100e18);
    }

    function testMint_RevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        receipt.mint(bob, 1);
    }

    function testBurn_DecreasesBalanceAndSupply() public {
        receipt.mint(alice, 100e18);
        receipt.burn(alice, 40e18);
        assertEq(receipt.balanceOf(alice), 60e18);
        assertEq(receipt.totalSupply(), 60e18);
    }

    function testBurn_RevertsWhenNotOwner() public {
        receipt.mint(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        receipt.burn(alice, 1);
    }

    function testApprove_AlwaysReverts() public {
        vm.expectRevert(IFlowReceipt.TransferDisabled.selector);
        receipt.approve(alice, type(uint256).max);
    }

    function testTransfer_AlwaysReverts() public {
        receipt.mint(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(IFlowReceipt.TransferDisabled.selector);
        receipt.transfer(bob, 1);
    }

    function testTransferFrom_AlwaysReverts() public {
        receipt.mint(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert();
        receipt.transferFrom(alice, bob, 1);
    }
}
