// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ILSPVaultConfig {
    struct Config {
        uint256 minRequestAmount;
        bool isStakingPaused;
        uint256 protocolFee;
        uint256 slippageTolerance;
    }

    error SlippageToleranceTooHigh(uint256 maxSlippageTolerance, uint256 slippageTolerance);
    
    function getConfig() external view returns (Config memory);
    function updateConfig(Config calldata _config) external;
    function setMinRequestAmount(uint256 _minRequestAmount) external;
    function setIsStakingPaused(bool _isStakingPaused) external;
    function setProtocolFee(uint256 _protocolFee) external;
    function setSlippageTolerance(uint256 _slippageTolerance) external;

    event ConfigUpdated(Config oldConfig, Config newConfig);
    event MinRequestAmountUpdated(uint256 oldMinRequestAmount, uint256 newMinRequestAmount);
    event IsStakingPausedUpdated(bool oldIsStakingPaused, bool newIsStakingPaused);
    event ProtocolFeeUpdated(uint256 oldProtocolFee, uint256 newProtocolFee);
    event SlippageToleranceUpdated(uint256 oldSlippageTolerance, uint256 newSlippageTolerance);
}
