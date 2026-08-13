// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILSPVaultConfig} from "./interfaces/ILSPVaultConfig.sol";

abstract contract LSPVaultConfig is Ownable, ILSPVaultConfig {
    ILSPVaultConfig.Config internal _config;

    uint256 private constant MAX_SLIPPAGE_TOLERANCE = 1e16; // 1%
    uint256 private constant MAX_PROTOCOL_FEE = 2e17; // 20%

    /// Wei per Cadence `UFix64` ulp (EVM 18 decimals − Cadence 8 decimals).
    uint256 public constant CADENCE_DECIMAL_SCALE = 1e10;

    constructor(address _owner, uint256 _minRequestAmount) Ownable(_owner) {
        if (_minRequestAmount == 0) revert MinRequestAmountMustBePositive();
        if (_minRequestAmount % CADENCE_DECIMAL_SCALE != 0) {
            revert MinRequestAmountNotCadenceRepresentable(_minRequestAmount);
        }
        _config.minRequestAmount = _minRequestAmount;
        _config.slippageTolerance = MAX_SLIPPAGE_TOLERANCE;
    }

    function getConfig() external view returns (ILSPVaultConfig.Config memory) {
        return _config;
    }

    function updateConfig(ILSPVaultConfig.Config calldata _newConfig) external onlyOwner {
        if (_newConfig.slippageTolerance > MAX_SLIPPAGE_TOLERANCE) {
            revert SlippageToleranceTooHigh(MAX_SLIPPAGE_TOLERANCE, _newConfig.slippageTolerance);
        }
        if (_newConfig.protocolFee > MAX_PROTOCOL_FEE) {
            revert ProtocolFeeTooHigh(MAX_PROTOCOL_FEE, _newConfig.protocolFee);
        }
        if (_newConfig.minRequestAmount == 0) revert MinRequestAmountMustBePositive();
        if (_newConfig.minRequestAmount % CADENCE_DECIMAL_SCALE != 0) {
            revert MinRequestAmountNotCadenceRepresentable(_newConfig.minRequestAmount);
        }
        emit ConfigUpdated(_config, _newConfig);
        _config = _newConfig;
    }

    function setMinRequestAmount(uint256 _minRequestAmount) external onlyOwner {
        if (_minRequestAmount == 0) revert MinRequestAmountMustBePositive();
        if (_minRequestAmount % CADENCE_DECIMAL_SCALE != 0) {
            revert MinRequestAmountNotCadenceRepresentable(_minRequestAmount);
        }
        emit MinRequestAmountUpdated(_config.minRequestAmount, _minRequestAmount);
        _config.minRequestAmount = _minRequestAmount;
    }

    function setIsStakingPaused(bool _isStakingPaused) external onlyOwner {
        emit IsStakingPausedUpdated(_config.isStakingPaused, _isStakingPaused);
        _config.isStakingPaused = _isStakingPaused;
    }

    function setProtocolFee(uint256 _protocolFee) external onlyOwner {
        if (_protocolFee > MAX_PROTOCOL_FEE) {
            revert ProtocolFeeTooHigh(MAX_PROTOCOL_FEE, _protocolFee);
        }
        emit ProtocolFeeUpdated(_config.protocolFee, _protocolFee);
        _config.protocolFee = _protocolFee;
    }

    function setSlippageTolerance(uint256 _slippageTolerance) external onlyOwner {
        if (_slippageTolerance > MAX_SLIPPAGE_TOLERANCE) {
            revert SlippageToleranceTooHigh(MAX_SLIPPAGE_TOLERANCE, _slippageTolerance);
        }
        emit SlippageToleranceUpdated(_config.slippageTolerance, _slippageTolerance);
        _config.slippageTolerance = _slippageTolerance;
    }
}
