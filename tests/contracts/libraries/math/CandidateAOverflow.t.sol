// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'tests/setup/Base.t.sol';

import {WadRayMath} from 'src/libraries/math/WadRayMath.sol';

/// @notice The envelope candidate A leaves, pinned deterministically.
/// @dev `AssetLogic.accrue` stores the debt index with
/// `asset.drawnIndex = drawnIndex.toUint120()`. `type(uint120).max` is about
/// 1.329e36, and the index starts at RAY (1e27), so the index may grow by a
/// factor of about 1.329e9 before the cast reverts. Linear interest reaches that
/// factor only after implausible time. Compounding reaches it at `rate * time`
/// of about ln(1.329e9) = 21, which is inside the configurable range.
///
/// The fuzzer found this as `SafeCastOverflowedUintDowncast(120, 1.541e36)`.
/// These tests name the boundary instead of relying on a seed.
/// forge-config: default.allow_internal_expect_revert = true
contract CandidateAOverflowTest is Base {
  using WadRayMath for uint256;
  using SafeCast for uint256;

  uint256 internal constant RAY = 1e27;
  uint256 internal constant UINT120_MAX = type(uint120).max;

  /// @notice Compounded accrual, `steps` times over `total` seconds.
  function _compounded(uint96 rate, uint256 total, uint256 steps) internal returns (uint256) {
    uint256 index = RAY;
    uint256 slice = total / steps;
    for (uint256 i = 0; i < steps; ++i) {
      uint40 last = uint40(vm.getBlockTimestamp());
      skip(slice);
      index = index.rayMulUp(MathUtils.calculateCompoundedInterest(rate, last));
    }
    return index;
  }

  function test_uint120CeilingIsWhereItIsClaimedToBe() public pure {
    // 2^120 - 1, and the factor above a RAY-based starting index.
    assertEq(UINT120_MAX, 1329227995784915872903807060280344575);
    assertEq(UINT120_MAX / RAY, 1329227995);
  }

  /// @notice Linear interest stays inside the envelope over the same span.
  function test_linearStaysInsideTheEnvelope() public {
    uint96 rate = type(uint96).max; // about 7900% per year in RAY
    uint256 index = RAY;
    uint40 last = uint40(vm.getBlockTimestamp());
    skip(365 days * 3);
    index = index.rayMulUp(MathUtils.calculateLinearInterest(rate, last));
    assertLt(index, UINT120_MAX);
    index.toUint120(); // does not revert
  }

  /// @notice Compounded interest leaves it, and the cast is where accrual dies.
  /// @dev Stops one step past the ceiling. Running the same rate for years
  /// instead reverts earlier and elsewhere, which the next test locates.
  function test_compoundedOverflowsTheStoredIndex() public {
    uint96 rate = type(uint96).max;
    uint256 index = RAY;
    while (index <= UINT120_MAX) {
      uint40 last = uint40(vm.getBlockTimestamp());
      skip(1 days);
      index = index.rayMulUp(MathUtils.calculateCompoundedInterest(rate, last));
    }
    assertGt(index, UINT120_MAX);

    // The exact call `AssetLogic.accrue` makes on this value.
    vm.expectRevert(
      abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 120, index)
    );
    index.toUint120();
  }

  /// @notice Past the ceiling the arithmetic itself stops working.
  /// @dev The index keeps multiplying, so a run long enough overflows uint256
  /// inside `rayMulUp` before any cast is reached. A protocol that let the
  /// index get here would already be bricked by the cast, so this is the second
  /// wall rather than the first, but it means the failure is not a single
  /// well-behaved revert an operator could catch and cure.
  function test_compoundedEventuallyOverflowsTheArithmetic() public {
    uint96 rate = type(uint96).max;
    uint256 index = RAY;
    uint256 day = 0;
    bool reverted = false;
    while (day < 400) {
      uint40 last = uint40(vm.getBlockTimestamp());
      skip(1 days);
      uint256 factor = MathUtils.calculateCompoundedInterest(rate, last);
      (bool ok, ) = address(this).call(
        abi.encodeWithSelector(this.mulOrRevert.selector, index, factor)
      );
      if (!ok) {
        reverted = true;
        break;
      }
      index = index.rayMulUp(factor);
      ++day;
    }
    assertTrue(reverted, 'arithmetic never gave way inside the search window');
    console.log('daily accruals until the arithmetic reverts:', day);
  }

  /// @dev External so the failure can be caught rather than aborting the test.
  function mulOrRevert(uint256 a, uint256 b) external pure returns (uint256) {
    return a.rayMulUp(b);
  }

  /// @notice The first daily step at which the cast starts reverting.
  /// @dev Reported rather than asserted as a threshold to defend: it is a
  /// property of this rate and this step size, and it is well inside what the
  /// type allows an operator to configure.
  function test_findTheDayAccrualDies() public {
    uint96 rate = type(uint96).max;
    uint256 index = RAY;
    uint256 day = 0;
    while (day < 4000) {
      uint40 last = uint40(vm.getBlockTimestamp());
      skip(1 days);
      index = index.rayMulUp(MathUtils.calculateCompoundedInterest(rate, last));
      ++day;
      if (index > UINT120_MAX) break;
    }
    assertGt(index, UINT120_MAX, 'never overflowed inside the search window');
    console.log('rate, RAY units          :', uint256(rate) / RAY);
    console.log('daily accruals until dead:', day);
    console.log('days as years            :', day / 365);
  }
}
