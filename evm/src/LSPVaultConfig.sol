// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILSPVaultConfig} from "./interfaces/ILSPVaultConfig.sol";

abstract contract LSPVaultConfig is Ownable, ILSPVaultConfig {
    ILSPVaultConfig.Config internal _config;

    uint256 private constant MAX_SLIPPAGE_TOLERANCE = 1e16; // 1%

    constructor(address _owner) Ownable(_owner) {
        _config.slippageTolerance = MAX_SLIPPAGE_TOLERANCE;
    }

    function getConfig() external view returns (ILSPVaultConfig.Config memory) {
        return _config;
    }

    function updateConfig(ILSPVaultConfig.Config calldata _newConfig) external onlyOwner {
        emit ConfigUpdated(_config, _newConfig);
        _config = _newConfig;
    }

    function setMinRequestAmount(uint256 _minRequestAmount) external onlyOwner {
        emit MinRequestAmountUpdated(_config.minRequestAmount, _minRequestAmount);
        _config.minRequestAmount = _minRequestAmount;
    }

    function setIsStakingPaused(bool _isStakingPaused) external onlyOwner {
        emit IsStakingPausedUpdated(_config.isStakingPaused, _isStakingPaused);
        _config.isStakingPaused = _isStakingPaused;
    }

    function setProtocolFee(uint256 _protocolFee) external onlyOwner {
        emit ProtocolFeeUpdated(_config.protocolFee, _protocolFee);
        _config.protocolFee = _protocolFee;
    }

    function setSlippageTolerance(uint256 _slippageTolerance) external onlyOwner {
        if (_slippageTolerance > MAX_SLIPPAGE_TOLERANCE) revert SlippageToleranceTooHigh(MAX_SLIPPAGE_TOLERANCE, _slippageTolerance);
        emit SlippageToleranceUpdated(_config.slippageTolerance, _slippageTolerance);
        _config.slippageTolerance = _slippageTolerance;
    }
}
