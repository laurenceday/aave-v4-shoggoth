// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.28;

import {LiquidationLogic} from 'src/spoke/libraries/LiquidationLogic.sol';
import {BabylonLiquidationLogic} from 'src/spoke/libraries/BabylonLiquidationLogic.sol';
import {IBabylonSpoke} from 'src/spoke/interfaces/IBabylonSpoke.sol';
import {ISpoke} from 'src/spoke/interfaces/ISpoke.sol';
import {Spoke} from 'src/spoke/Spoke.sol';

/// @title BabylonSpoke
/// @author Aave Labs
/// @notice Spoke variant for the Babylon integration: liquidations are restricted to a configured
/// liquidation manager and sized by a collateral cap instead of a target health factor.
abstract contract BabylonSpoke is IBabylonSpoke, Spoke {
  /// @dev The only address allowed to perform liquidations on this Spoke.
  address internal _liquidationManager;

  /// @inheritdoc IBabylonSpoke
  function updateLiquidationManager(address liquidationManager) external restricted {
    _liquidationManager = liquidationManager;
    emit UpdateLiquidationManager(liquidationManager);
  }

  /// @dev The canonical liquidation entry point is disabled on this Spoke: liquidations go
  /// through the manager-gated, cap-bounded `liquidationCall` overload.
  function liquidationCall(
    uint256,
    uint256,
    address,
    uint256,
    bool
  ) external pure override(ISpoke, Spoke) {
    revert UnsupportedLiquidationCall();
  }

  /// @inheritdoc IBabylonSpoke
  function liquidationCall(
    uint256 collateralReserveId,
    uint256[] calldata debtReserveIds,
    uint256[] calldata debtAmounts,
    address user,
    uint256 maxCollateralToReceive
  ) external nonReentrant {
    require(msg.sender == _liquidationManager, Unauthorized());

    UserAccountData memory userAccountData = _calculateUserAccountData(user);
    BabylonLiquidationLogic.LiquidateUserParams memory params = BabylonLiquidationLogic
      .LiquidateUserParams({
        collateralReserveId: collateralReserveId,
        debtReserveIds: debtReserveIds,
        debtAmounts: debtAmounts,
        liquidationConfig: _liquidationConfig,
        oracle: ORACLE,
        user: user,
        maxCollateralToReceive: maxCollateralToReceive,
        userAccountData: userAccountData,
        liquidator: msg.sender
      });

    bool isUserInDeficit = BabylonLiquidationLogic.liquidateUser({
      reserves: _reserves,
      userPositions: _userPositions,
      positionStatus: _positionStatus,
      dynamicConfig: _dynamicConfig,
      params: params
    });

    if (isUserInDeficit) {
      // report deficit for all debt reserves, including the reserve being repaid
      LiquidationLogic.notifyReportDeficit(
        _reserves,
        _userPositions,
        _positionStatus,
        _reserveCount,
        user
      );
    } else {
      uint256 newRiskPremium = _calculateUserAccountData(user).riskPremium;
      _notifyRiskPremiumUpdate(user, newRiskPremium);
    }
  }

  /// @inheritdoc IBabylonSpoke
  function getLiquidationManager() external view returns (address) {
    return _liquidationManager;
  }
}
