// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFlowReceipt} from "./interfaces/IFlowReceipt.sol";

/**
 * @title FlowReceipt
 * @notice A contract that allows the owner to mint and burn Flow Receipts to keep accounting intact.
 */
contract FlowReceipt is Ownable, ERC20, IFlowReceipt {
    constructor() Ownable(msg.sender) ERC20("sFlow Receipt", "sFR") {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert TransferDisabled();
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert TransferDisabled();
        super._update(from, to, value);
    }
}
