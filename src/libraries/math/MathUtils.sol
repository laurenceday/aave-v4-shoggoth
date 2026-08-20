// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.20;

import {SafeCast} from 'src/dependencies/openzeppelin/SafeCast.sol';

/// @title MathUtils library
/// @author Aave Labs
library MathUtils {
  using SafeCast for uint256;

  uint256 internal constant RAY = 1e27;
  /// @dev Ignoring leap years
  uint256 internal constant SECONDS_PER_YEAR = 365 days;

  /// @notice Calculates the interest accumulated using a linear interest rate formula.
  /// @dev Reverts if `lastUpdateTimestamp` is greater than `block.timestamp`.
  /// @param rate The interest rate, expressed in RAY.
  /// @param lastUpdateTimestamp The timestamp to calculate interest rate from.
  /// @return result The interest rate linearly accumulated during the time delta, expressed in RAY.
  function calculateLinearInterest(
    uint96 rate,
    uint40 lastUpdateTimestamp
  ) internal view returns (uint256 result) {
    assembly ('memory-safe') {
      if gt(lastUpdateTimestamp, timestamp()) {
        revert(0, 0)
      }
      result := sub(timestamp(), lastUpdateTimestamp)
      result := add(div(mul(rate, result), SECONDS_PER_YEAR), RAY)
    }
  }

  /// @dev Candidate B for aave/aave-v4#853. The period the debt index is allowed
  /// to compound over. The issue's own mitigation family is to express the rate
  /// on a coarser basis than per-second; quantising accrual to whole periods
  /// reaches the same place without an on-chain root, because time inside a
  /// period cannot be split into extra compounding steps.
  uint256 internal constant COMPOUNDING_PERIOD = 7 days;

  /// @notice The number of whole compounding periods between a timestamp and now.
  /// @dev Reverts if `lastUpdateTimestamp` is greater than `block.timestamp`.
  function wholePeriodsElapsed(uint40 lastUpdateTimestamp) internal view returns (uint256) {
    if (lastUpdateTimestamp > block.timestamp) {
      revert();
    }
    return (block.timestamp - lastUpdateTimestamp) / COMPOUNDING_PERIOD;
  }

  /// @notice Linear interest over whole compounding periods only.
  /// @dev Candidate B for aave/aave-v4#853. Interest for the part-period since
  /// the last boundary is not dropped: it is left for the next accrual to pick
  /// up, because the caller advances `lastUpdateTimestamp` by whole periods
  /// rather than to `block.timestamp`. Accruing a thousand times inside one
  /// period therefore produces the same index as accruing once at its end.
  /// @param rate The interest rate, expressed in RAY.
  /// @param lastUpdateTimestamp The timestamp to calculate interest rate from.
  /// @return The interest accumulated over the whole periods elapsed, in RAY.
  function calculateQuantisedLinearInterest(
    uint96 rate,
    uint40 lastUpdateTimestamp
  ) internal view returns (uint256) {
    uint256 periods = wholePeriodsElapsed(lastUpdateTimestamp);
    if (periods == 0) {
      return RAY;
    }
    return RAY + (uint256(rate) * periods * COMPOUNDING_PERIOD) / SECONDS_PER_YEAR;
  }

  /// @notice Returns the smaller of two unsigned integers.
  function min(uint256 a, uint256 b) internal pure returns (uint256 result) {
    assembly ('memory-safe') {
      result := xor(b, mul(xor(a, b), lt(a, b)))
    }
  }

  /// @notice Returns the saturating subtraction at zero.
  function zeroFloorSub(uint256 a, uint256 b) internal pure returns (uint256 c) {
    assembly ('memory-safe') {
      c := mul(sub(a, b), gt(a, b))
    }
  }

  /// @notice Returns the sum of an unsigned and signed integer.
  /// @dev Reverts on underflow.
  function add(uint256 a, int256 b) internal pure returns (uint256) {
    if (b >= 0) return a + uint256(b);
    return a - uint256(-b);
  }

  /// @notice Returns the sum of two unsigned integers.
  /// @dev Does not revert on overflow.
  function uncheckedAdd(uint256 a, uint256 b) internal pure returns (uint256) {
    unchecked {
      return a + b;
    }
  }

  /// @notice Returns the difference of two unsigned integers as a signed integer.
  function signedSub(uint256 a, uint256 b) internal pure returns (int256) {
    return a.toInt256() - b.toInt256();
  }

  /// @notice Returns the difference of two unsigned integers.
  /// @dev Does not revert on underflow.
  function uncheckedSub(uint256 a, uint256 b) internal pure returns (uint256) {
    unchecked {
      return a - b;
    }
  }

  /// @notice Raises an unsigned integer to the power of an unsigned integer.
  /// @dev Does not revert on overflow.
  function uncheckedExp(uint256 a, uint256 b) internal pure returns (uint256) {
    unchecked {
      return a ** b;
    }
  }

  /// @notice Divides `a` by `b`, rounding up.
  /// @dev Reverts if division by zero.
  /// @return c = ceil(a / b).
  function divUp(uint256 a, uint256 b) internal pure returns (uint256 c) {
    assembly ('memory-safe') {
      if iszero(b) {
        revert(0, 0)
      }
      c := add(div(a, b), gt(mod(a, b), 0))
    }
  }

  /// @notice Multiplies `a` and `b` in 256 bits and divides the result by `c`, rounding down.
  /// @dev Reverts if division by zero or overflow occurs on intermediate multiplication.
  /// @return d = floor(a * b / c).
  function mulDivDown(uint256 a, uint256 b, uint256 c) internal pure returns (uint256 d) {
    // to avoid overflow, a <= type(uint256).max / b
    assembly ('memory-safe') {
      if iszero(c) {
        revert(0, 0)
      }
      if iszero(or(iszero(b), iszero(gt(a, div(not(0), b))))) {
        revert(0, 0)
      }
      d := div(mul(a, b), c)
    }
  }

  /// @notice Multiplies `a` and `b` in 256 bits and divides the result by `c`, rounding up.
  /// @dev Reverts if division by zero or overflow occurs on intermediate multiplication.
  /// @return d = ceil(a * b / c).
  function mulDivUp(uint256 a, uint256 b, uint256 c) internal pure returns (uint256 d) {
    // to avoid overflow, a <= type(uint256).max / b
    assembly ('memory-safe') {
      if iszero(c) {
        revert(0, 0)
      }
      if iszero(or(iszero(b), iszero(gt(a, div(not(0), b))))) {
        revert(0, 0)
      }
      d := mul(a, b)
      // add 1 if (a * b) % c > 0 to round up the division of (a * b) by c
      d := add(div(d, c), gt(mod(d, c), 0))
    }
  }
}
