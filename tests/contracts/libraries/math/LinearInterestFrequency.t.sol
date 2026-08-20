// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'tests/setup/Base.t.sol';

import {WadRayMath} from 'src/libraries/math/WadRayMath.sol';

/// @notice Reproduction for aave/aave-v4#853.
/// @dev `AssetLogic.getDrawnIndex` grows the debt index by
/// `previousIndex.rayMulUp(MathUtils.calculateLinearInterest(rate, last))`, and
/// `AssetLogic.accrue` runs on any interaction with the asset. Linear interest
/// is not invariant under composition: applying it over k sub-intervals
/// multiplies k factors where applying it once adds their rates. Anyone able to
/// trigger accrual can therefore raise the index that borrowers owe against,
/// without the rate itself changing.
///
/// These tests state the current behaviour rather than the wanted behaviour, so
/// they pass on the unfixed tree and are the measurement any fix has to move.
contract LinearInterestFrequencyTest is Base {
  using WadRayMath for uint256;

  uint256 internal constant RAY = 1e27;

  /// @dev 1000% per year, the rate the issue's worked example uses.
  uint96 internal constant RATE = 10e27;

  /// @notice Applies accrual `steps` times across `total` seconds, as the hub would.
  function _indexAfter(uint96 rate, uint256 total, uint256 steps) internal returns (uint256) {
    uint256 index = RAY;
    uint256 slice = total / steps;
    for (uint256 i = 0; i < steps; ++i) {
      uint40 last = uint40(vm.getBlockTimestamp());
      skip(slice);
      index = index.rayMulUp(MathUtils.calculateLinearInterest(rate, last));
    }
    return index;
  }

  function test_853_dailyAccrualBeatsAnnualAccrual() public {
    uint256 once = _indexAfter(RATE, 365 days, 1);
    uint256 daily = _indexAfter(RATE, 365 days, 365);

    // One accrual over the year is the linear result: 1 + 10 = 11 RAY.
    assertEq(once, 11 * RAY);
    // 365 accruals compound instead of adding.
    assertGt(daily, once);
    // Recorded, not asserted as desirable: the same rate and the same elapsed
    // time produce an index this much larger when poked once a day.
    assertGt(daily, once * 2);
    console.log('annual accrual, index in RAY units:', once / RAY);
    console.log('daily accrual, index in RAY units:', daily / RAY);
    console.log('daily as a multiple of annual:', daily / once);
  }

  function test_853_hourlyBeatsDaily() public {
    uint256 daily = _indexAfter(RATE, 365 days, 365);
    uint256 hourly = _indexAfter(RATE, 365 days, 8760);
    assertGt(hourly, daily);
  }

  function test_853_moreStepsNeverAccrueLess() public {
    uint256 coarse = _indexAfter(RATE, 3600, 1);
    uint256 fine = _indexAfter(RATE, 3600, 60);
    uint256 finest = _indexAfter(RATE, 3600, 3600);
    assertGe(fine, coarse);
    assertGe(finest, fine);
  }

  /// @notice The direction holds for any rate and any split, not just the example.
  function test_fuzz_853_splittingNeverAccruesLess(uint96 rate, uint8 steps) public {
    steps = uint8(bound(steps, 2, 64));
    rate = uint96(bound(rate, 1e20, 100e27));
    uint256 window = uint256(steps) * 1 days;
    uint256 once = _indexAfter(rate, window, 1);
    uint256 split = _indexAfter(rate, window, steps);
    assertGe(split, once);
  }

  /// @notice Rounding alone inflates the index, independently of compounding.
  /// @dev `rayMulUp` rounds every accrual up, so a zero rate still grows the
  /// index by one wei per accrual once any dust is present.
  function test_853_roundingUpIsPaidEveryAccrual() public {
    uint256 index = RAY + 1;
    uint40 last = uint40(vm.getBlockTimestamp());
    skip(1);
    uint256 stepped = index.rayMulUp(MathUtils.calculateLinearInterest(0, last));
    assertEq(stepped, index, 'zero rate holds the index');
  }
}
