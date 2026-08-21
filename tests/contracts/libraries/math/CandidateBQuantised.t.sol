// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'tests/setup/Base.t.sol';

import {WadRayMath} from 'src/libraries/math/WadRayMath.sol';

/// @notice Candidate B for aave/aave-v4#853, and the envelope it leaves.
/// @dev Quantising accrual to whole compounding periods removes the frequency
/// dependence by construction: time inside a period cannot be split into extra
/// compounding steps, because the clock only advances on period boundaries.
/// These tests measure what it fixes, what it costs, and where it breaks.
/// forge-config: default.allow_internal_expect_revert = true
contract CandidateBQuantisedTest is Base {
  using WadRayMath for uint256;
  using SafeCast for uint256;

  uint256 internal constant RAY = 1e27;
  uint256 internal constant UINT120_MAX = type(uint120).max;
  uint96 internal constant RATE = 10e27; // 1000% per year

  /// @notice Quantised accrual, `steps` times over `total` seconds, advancing the
  /// clock the way `AssetLogic.accrue` now does.
  function _quantised(uint96 rate, uint256 total, uint256 steps) internal returns (uint256) {
    uint256 index = RAY;
    uint40 last = uint40(vm.getBlockTimestamp());
    uint256 slice = total / steps;
    for (uint256 i = 0; i < steps; ++i) {
      skip(slice);
      index = index.rayMulUp(MathUtils.calculateQuantisedLinearInterest(rate, last));
      uint256 periods = MathUtils.wholePeriodsElapsed(last);
      if (periods != 0) {
        last = uint40(last + periods * MathUtils.COMPOUNDING_PERIOD);
      }
    }
    return index;
  }

  function test_periodIsAWeek() public pure {
    assertEq(MathUtils.COMPOUNDING_PERIOD, 7 days);
  }

  /// @notice The property the linear form lacks and the whole point of B.
  function test_frequencyStopsMattering() public {
    uint256 weekly = _quantised(RATE, 364 days, 52);
    uint256 daily = _quantised(RATE, 364 days, 364);
    uint256 hourly = _quantised(RATE, 364 days, 8736);
    console.log('quantised, weekly accrual:', weekly / RAY);
    console.log('quantised, daily accrual :', daily / RAY);
    console.log('quantised, hourly accrual:', hourly / RAY);
    assertEq(weekly, daily);
    assertEq(daily, hourly);
  }

  /// @notice Against the unfixed behaviour, on the same rate and window.
  function test_gapAgainstTheUnfixedForm() public {
    uint256 quantised = _quantised(RATE, 364 days, 364);

    uint256 linear = RAY;
    uint40 last = uint40(vm.getBlockTimestamp());
    for (uint256 i = 0; i < 364; ++i) {
      last = uint40(vm.getBlockTimestamp());
      skip(1 days);
      linear = linear.rayMulUp(MathUtils.calculateLinearInterest(RATE, last));
    }
    console.log('quantised, daily accrual :', quantised / RAY);
    console.log('unfixed,   daily accrual :', linear / RAY);
    assertLt(quantised, linear);
  }

  /// @notice The envelope, measured rather than assumed.
  /// @dev B compounds at most once a period instead of once a second, so it
  /// reaches the stored index's ceiling later than candidate A. Later is not
  /// never: at the maximum configurable rate a weekly factor of about 2.5 still
  /// leaves a uint120 well inside a year. The ceiling belongs to the index's
  /// storage type, not to either candidate, and neither candidate is safe at
  /// that rate.
  function test_envelopeIsReachedLaterButStillReached() public {
    uint96 rate = type(uint96).max;
    uint256 index = RAY;
    uint40 last = uint40(vm.getBlockTimestamp());
    uint256 weeks_ = 0;
    while (weeks_ < 520) {
      skip(7 days);
      index = index.rayMulUp(MathUtils.calculateQuantisedLinearInterest(rate, last));
      last = uint40(last + MathUtils.COMPOUNDING_PERIOD);
      ++weeks_;
      if (index > UINT120_MAX) break;
    }
    assertGt(index, UINT120_MAX, 'never overflowed inside the search window');
    console.log('rate, RAY units             :', uint256(rate) / RAY);
    console.log('weekly accruals until dead  :', weeks_);
    console.log('as days                     :', weeks_ * 7);
  }

  /// @notice At a rate an operator would plausibly set, the envelope is fine.
  function test_envelopeHoldsAtAPlausibleRate() public {
    uint96 rate = 0.2e27; // 20% per year
    uint256 index = _quantised(rate, 365 days * 10, 520);
    console.log('quantised, 20 percent, ten years, index/RAY:', index / RAY);
    assertLt(index, UINT120_MAX);
    index.toUint120(); // the exact call accrue() makes; does not revert
  }

  /// @notice The cost, stated as plainly as the benefit.
  /// @dev Interest is credited only when a period boundary is crossed, so a
  /// position opened and closed inside one period accrues nothing at all. That
  /// is a real loss to lenders and a real gift to short-term borrowers, and it
  /// is the price of removing the frequency dependence this way.
  function test_costPartPeriodsAccrueNothing() public {
    uint40 last = uint40(vm.getBlockTimestamp());
    skip(6 days);
    assertEq(MathUtils.calculateQuantisedLinearInterest(RATE, last), RAY);
    assertEq(MathUtils.wholePeriodsElapsed(last), 0);

    skip(1 days);
    assertGt(MathUtils.calculateQuantisedLinearInterest(RATE, last), RAY);
    assertEq(MathUtils.wholePeriodsElapsed(last), 1);
  }

  /// @notice The remainder is carried rather than lost across accruals.
  function test_remainderSurvivesAnAccrual() public {
    uint40 last = uint40(vm.getBlockTimestamp());
    skip(10 days);
    uint256 periods = MathUtils.wholePeriodsElapsed(last);
    assertEq(periods, 1);
    uint40 advanced = uint40(last + periods * MathUtils.COMPOUNDING_PERIOD);

    // Three days remain on the clock, so four more days reach the next period.
    assertEq(MathUtils.wholePeriodsElapsed(advanced), 0);
    skip(4 days);
    assertEq(MathUtils.wholePeriodsElapsed(advanced), 1);
  }

  function test_futureTimestampStillReverts() public {
    uint40 future = uint40(vm.getBlockTimestamp() + 1);
    vm.expectRevert();
    MathUtils.calculateQuantisedLinearInterest(RATE, future);
  }
}
