// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {WadRayMath} from 'src/libraries/math/WadRayMath.sol';

/// @title CompoundedInterestCandidate
/// @notice A candidate mitigation for aave/aave-v4#853, kept in the test tree.
/// @dev This is the Aave V2/V3 `calculateCompoundedInterest` shape: a three-term
/// binomial approximation of `e^(rate * t)`. V2 and V3 used the linear form for
/// the liquidity index and this form for the variable debt index, precisely so
/// that debt accrual did not depend on how often anyone triggered it.
///
/// It lives under `tests/` rather than in `src/libraries/math/MathUtils.sol` on
/// purpose. Nothing here is proposed as the fix yet: the point is to measure
/// what each candidate does to the frequency gap and what it costs, before any
/// decision is taken about the hot path in `AssetLogic.getDrawnIndex`.
library CompoundedInterestCandidate {
  using WadRayMath for uint256;

  uint256 internal constant RAY = 1e27;
  uint256 internal constant SECONDS_PER_YEAR = 365 days;

  /// @notice Approximates `RAY * e^(rate * exp / SECONDS_PER_YEAR)`.
  /// @param rate The annual interest rate, expressed in RAY.
  /// @param exp The elapsed seconds.
  function calculateCompoundedInterest(
    uint256 rate,
    uint256 exp
  ) internal pure returns (uint256) {
    if (exp == 0) {
      return RAY;
    }

    uint256 expMinusOne = exp - 1;
    uint256 expMinusTwo = exp > 2 ? exp - 2 : 0;

    uint256 base = rate / SECONDS_PER_YEAR;

    // V2/V3 used a half-up `rayMul` here. V4's WadRayMath makes rounding
    // explicit and offers no such function, so the power terms round down:
    // that understates the second and third terms rather than overstating
    // them, which is the safe direction for a term that raises debt.
    uint256 basePowerTwo = base.rayMulDown(base);
    uint256 basePowerThree = basePowerTwo.rayMulDown(base);

    uint256 secondTerm = (exp * expMinusOne * basePowerTwo) / 2;
    uint256 thirdTerm = (exp * expMinusOne * expMinusTwo * basePowerThree) / 6;

    return RAY + (base * exp) + secondTerm + thirdTerm;
  }
}
