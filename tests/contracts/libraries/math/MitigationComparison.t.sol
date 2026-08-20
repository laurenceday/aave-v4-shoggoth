// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'tests/setup/Base.t.sol';

import {WadRayMath} from 'src/libraries/math/WadRayMath.sol';
import {CompoundedInterestCandidate} from './CompoundedInterestCandidate.sol';

/// @notice Measures each candidate mitigation for aave/aave-v4#853 against the
/// gap the reproduction records, and prices it.
/// @dev Decides nothing. Two candidates are on the table: the V2/V3 compounded
/// debt index, and the reporter's own suggestion of decompounding the annual
/// rate to a coarser period before linearising it. Each is measured on the same
/// rate, the same window and the same accrual frequencies.
contract MitigationComparisonTest is Base {
  using WadRayMath for uint256;

  uint256 internal constant RAY = 1e27;
  uint96 internal constant RATE = 10e27; // 1000% per year

  /// @notice Current behaviour: linear interest applied `steps` times.
  function _linear(uint96 rate, uint256 total, uint256 steps) internal returns (uint256) {
    uint256 index = RAY;
    uint256 slice = total / steps;
    for (uint256 i = 0; i < steps; ++i) {
      uint40 last = uint40(vm.getBlockTimestamp());
      skip(slice);
      index = index.rayMulUp(MathUtils.calculateLinearInterest(rate, last));
    }
    return index;
  }

  /// @notice Candidate A: the V2/V3 compounded debt index, applied `steps` times.
  function _compounded(uint256 rate, uint256 total, uint256 steps) internal pure returns (uint256) {
    uint256 index = RAY;
    uint256 slice = total / steps;
    for (uint256 i = 0; i < steps; ++i) {
      index = index.rayMulUp(
        CompoundedInterestCandidate.calculateCompoundedInterest(rate, slice)
      );
    }
    return index;
  }

  function test_currentBehaviour_frequencyGap() public {
    uint256 once = _linear(RATE, 365 days, 1);
    uint256 daily = _linear(RATE, 365 days, 365);
    console.log('linear, annual accrual  :', once / RAY);
    console.log('linear, daily accrual   :', daily / RAY);
    console.log('linear gap, x           :', daily / once);
    assertGt(daily, once);
  }

  function test_candidateA_compoundedIsFrequencyInvariantWhereItMatters() public pure {
    uint256 daily = _compounded(RATE, 365 days, 365);
    uint256 hourly = _compounded(RATE, 365 days, 8760);
    uint256 perMinute = _compounded(RATE, 365 days, 525600);
    console.log('compounded, daily accrual   :', daily / RAY);
    console.log('compounded, hourly accrual  :', hourly / RAY);
    console.log('compounded, per-minute      :', perMinute / RAY);

    // This is the property the linear form lacks: the frequency stops mattering.
    assertEq(daily / RAY, hourly / RAY);
    assertEq(hourly / RAY, perMinute / RAY);
  }

  /// @notice The candidate's own limit, stated rather than hidden.
  /// @dev The three-term binomial approximates `e^x` well only for small `x`.
  /// One 365-day step at 1000% means x = 10, where three terms give
  /// 1 + 10 + 50 + 166 = 227 against a true e^10 of 22026. V2 and V3 lived with
  /// this because debt accrues far more often than annually, but a fix resting
  /// on it owes that assumption out loud.
  function test_candidateA_singleAnnualStepUnderstatesBadly() public pure {
    uint256 once = _compounded(RATE, 365 days, 1);
    uint256 daily = _compounded(RATE, 365 days, 365);
    console.log('compounded, one 365-day step:', once / RAY);
    console.log('compounded, daily accrual   :', daily / RAY);
    assertLt(once, daily);
  }

  function test_candidateB_weeklyDecompoundingLandsNearTheIntendedRate() public {
    // The reporter's suggestion is to decompound the annual rate into a weekly
    // one before linearising: a 1000% annual target is ~4.71% per week, since
    // 1.0471^52 is about 11. Expressed on the annual basis this function takes,
    // 4.71% per week is 0.0471 * (365 / 7) = ~2.4559 in RAY.
    uint96 weeklyBasis = 2.4559e27;

    uint256 daily = _linear(weeklyBasis, 365 days, 365);
    console.log('candidate B, daily accrual  :', daily / RAY);
    // Against the linear form's 19253, and an intended 11.
    assertLt(daily, 20 * RAY);

    // The cost the reporter names, reproduced: trigger accrual less often than
    // the period the rate was decompounded for, and borrowers underpay.
    uint256 annual = _linear(weeklyBasis, 365 days, 1);
    console.log('candidate B, annual accrual :', annual / RAY);
    assertLt(annual, daily);
  }

  function test_gas_singleStepEachWay() public {
    uint40 last = uint40(vm.getBlockTimestamp());
    skip(1 days);

    uint256 gasBefore = gasleft();
    MathUtils.calculateLinearInterest(RATE, last);
    uint256 linearGas = gasBefore - gasleft();

    gasBefore = gasleft();
    CompoundedInterestCandidate.calculateCompoundedInterest(RATE, 1 days);
    uint256 compoundedGas = gasBefore - gasleft();

    console.log('gas, calculateLinearInterest    :', linearGas);
    console.log('gas, calculateCompoundedInterest:', compoundedGas);
    console.log('gas, difference                 :', compoundedGas - linearGas);
    assertGt(compoundedGas, linearGas, 'compounding is not free');
  }
}
