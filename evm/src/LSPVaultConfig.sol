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
        if (_newConfig.slippageTolerance > MAX_SLIPPAGE_TOLERANCE) {
            revert SlippageToleranceTooHigh(MAX_SLIPPAGE_TOLERANCE, _newConfig.slippageTolerance);
        }
        ILSPVaultConfig.Config memory oldConfig = _config;
        _config = _newConfig;
        emit ConfigUpdated(oldConfig, _newConfig);
    }

    function setMinRequestAmount(uint256 _minRequestAmount) external onlyOwner {
        uint256 oldMinRequestAmount = _config.minRequestAmount;
        _config.minRequestAmount = _minRequestAmount;
        emit MinRequestAmountUpdated(oldMinRequestAmount, _minRequestAmount);
    }

    function setIsStakingPaused(bool _isStakingPaused) external onlyOwner {
        bool oldIsStakingPaused = _config.isStakingPaused;
        _config.isStakingPaused = _isStakingPaused;
        emit IsStakingPausedUpdated(oldIsStakingPaused, _isStakingPaused);
    }

    function setProtocolFee(uint256 _protocolFee) external onlyOwner {
        uint256 oldProtocolFee = _config.protocolFee;
        _config.protocolFee = _protocolFee;
        emit ProtocolFeeUpdated(oldProtocolFee, _protocolFee);
    }

    function setSlippageTolerance(uint256 _slippageTolerance) external onlyOwner {
        if (_slippageTolerance > MAX_SLIPPAGE_TOLERANCE) revert SlippageToleranceTooHigh(MAX_SLIPPAGE_TOLERANCE, _slippageTolerance);
        uint256 oldSlippageTolerance = _config.slippageTolerance;
        _config.slippageTolerance = _slippageTolerance;
        emit SlippageToleranceUpdated(oldSlippageTolerance, _slippageTolerance);
    }
}
