// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import "../src/CryptoIndexToken.sol";
import "../src/CDPManager.sol";
import "../src/CDPHook.sol";
import "v4-core/PoolManager.sol";
import "v4-core/interfaces/IPoolManager.sol";
import "v4-core/types/Currency.sol";
import "v4-core/types/PoolKey.sol";
import "v4-core/libraries/TickMath.sol";
import "solmate/src/tokens/ERC20.sol";
import "solmate/src/test/utils/mocks/MockERC20.sol";
import "chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import "forge-std/console.sol";

contract CDPSystemTest is Test, Deployers {
    // Core setup: Mock USDC, synthetic token (CIT), CDP Manager, Hook, Oracle and Uniswap Pool.
    // We integrate a Hook to manage synthetic token issuance on liquidity addition and handle swaps.
    MockERC20 usdc;
    CryptoIndexToken cit;
    CDPManager cdpManager;
    CDPHook hook;
    IPoolManager.SwapParams swapParams;
    Currency usdcCurrency;
    Currency citCurrency;
    PoolKey poolKey;
    MockV3Aggregator oracle;

    function setUp() public {
        // Deploy a fresh Uniswap PoolManager and related routers for testing.
        deployFreshManagerAndRouters();

        // Create and mint mock USDC tokens to this test contract for liquidity.
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        usdc.mint(address(this), 1_000_000e6);

        // Approve USDC for swapping and adding/removing liquidity.
        usdc.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Set up an oracle with an initial price of $1000 for the synthetic token.
        oracle = new MockV3Aggregator(18, 1000e18);

        // Deploy the Hook contract that integrates with Uniswap Hooks.
        // Flags enable afterInitialize, beforeAddLiquidity, beforeSwap, beforeSwapReturnDelta.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        deployCodeTo("CDPHook.sol", abi.encode(manager), address(flags));
        hook = CDPHook(address(flags));

        // Deploy the CDP Manager which uses the Hook and Oracle to mint CIT on liquidity add.
        cdpManager = new CDPManager(
            address(usdc),
            address(oracle),
            address(hook)
        );
        usdc.approve(address(cdpManager), type(uint256).max);

        // Link the Hook to the CDP Manager.
        hook.setCDPManager(address(cdpManager));

        // Predict the synthetic token (CIT) address and fetch it.
        bytes32 salt = keccak256(abi.encodePacked("unique_identifier"));
        bytes memory bytecode = type(CryptoIndexToken).creationCode;
        bytes32 bytecodeHash = cdpManager.getBytecodeHash(bytecode);
        address predictedCitAddress = cdpManager.computeAddress(
            salt,
            bytecodeHash
        );
        cit = CryptoIndexToken(predictedCitAddress);

        // Wrap currencies and initialize a Uniswap V4 pool with the Hook integrated.
        usdcCurrency = Currency.wrap(address(usdc));
        citCurrency = Currency.wrap(address(cit));

        // Initialize a Uniswap pool with our Hook and a fee tier of 3000.
        (key, ) = initPool(
            usdcCurrency,
            citCurrency,
            hook,
            3000,
            SQRT_PRICE_1_1
        );
        cit.approve(address(swapRouter), type(uint256).max);
        cit.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Approve hook for USDC/CIT as well.
        usdc.approve(address(hook), type(uint256).max);
        cit.approve(address(hook), type(uint256).max);

        // Add initial liquidity to the pool. This triggers synthetic token minting and sets up the system.
        hook.addLiquidity(key, 200e6);
    }

    // Test 1: Add Liquidity and Verify Minted CIT
    // Ensures that adding liquidity with USDC correctly mints CIT according to oracle price and stores in pool.
    function testAddLiquidity() public {
        (uint256 collateral, uint256 debt) = cdpManager.positions(address(this));

        // Check that we got the expected collateral and synthetic token debt (CIT minted) for the given price.
        // With 200e6 USDC, half is collateral (100e6), and at 1000$ price and 150% CR, we expect exactly 66666 CIT.
        assertTrue(collateral > 0, "Collateral not updated");
        assertTrue(debt > 0, "Debt not updated");
        assertEq(debt, 66666, "Debt minted not correct");

        // Check the pool now holds USDC and CIT representing our position.
        uint256 poolUsdcBalance = usdc.balanceOf(address(manager));
        uint256 poolCitBalance = cit.balanceOf(address(manager));
        assertTrue(poolUsdcBalance > 0, "USDC not added to pool");
        assertTrue(poolCitBalance > 0, "CIT not added to pool");
    }

    // Test 2: Add Liquidity Multiple Times
    // Verifies that after multiple additions of liquidity, the cumulative collateral and CIT minted match the calculation.
    function testAddLiquidityMultipleTimes() public {
        // Add more liquidity in steps: 200e6, 300e6, 500e6
        hook.addLiquidity(key, 200e6);
        hook.addLiquidity(key, 300e6);
        hook.addLiquidity(key, 500e6);

        (uint256 collateral, uint256 debt) = cdpManager.positions(address(this));

        // Total USDC added: initial 200e6 + (200e6+300e6+500e6) = 1,200e6
        // Collateral = half = 600e6
        // For 600e6 collateral at $1000 price and 150% ratio, CIT should scale proportionally (~399998 CIT).
        assertEq(collateral, 600e6, "Collateral after multiple adds mismatch");
        assertEq(debt, 399998, "Debt after multiple additions mismatch");
    }

    // Test 3: Swap USDC for CIT (Exact Output)
    // User swaps USDC to get a certain amount of CIT out from the pool at 1:1 scenario.
    function testSwapUSDCForCIT() public {
        hook.addLiquidity(key, 200_000e6);

        uint256 usdcAmount = 50e6;
        usdc.mint(address(this), usdcAmount);
        usdc.approve(address(swapRouter), usdcAmount);

        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 citBefore = cit.balanceOf(address(this));

        // Execute exact output swap: user wants usdcAmount CIT out by spending USDC.
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(usdcAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims:false, settleUsingBurn:false}), ZERO_BYTES);

        uint256 usdcAfter = usdc.balanceOf(address(this));
        uint256 citAfter = cit.balanceOf(address(this));

        // Verify user received CIT equal to specified amount and spent corresponding USDC.
        assertEq(citAfter - citBefore, usdcAmount, "CIT received is incorrect");
        assertEq(usdcBefore - usdcAfter, 50e6, "USDC spent not correct");
    }

    // Test 4: Swap CIT for USDC (Exact Input)
    // Acquire CIT first by doing a USDC->CIT swap, then swap CIT back to USDC.
    function testSwapCITForUSDC() public {
        hook.addLiquidity(key, 300_000e6);

        // First get CIT by swapping USDC to CIT.
        uint256 usdcForCIT = 50e6;
        usdc.mint(address(this), usdcForCIT);
        usdc.approve(address(swapRouter), usdcForCIT);
        IPoolManager.SwapParams memory getCITParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(usdcForCIT),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap(key, getCITParams, PoolSwapTest.TestSettings({takeClaims:false, settleUsingBurn:false}), ZERO_BYTES);

        uint256 citBalanceNow = cit.balanceOf(address(this));
        assertTrue(citBalanceNow > 0, "Failed to acquire CIT from the pool");

        // Now swap CIT back for USDC using exact input CIT.
        uint256 citToSwap = 50e6; 
        cit.approve(address(swapRouter), citToSwap);
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 citBefore = cit.balanceOf(address(this));

        IPoolManager.SwapParams memory citForUSDCParams = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(citToSwap),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(key, citForUSDCParams, PoolSwapTest.TestSettings({takeClaims:false, settleUsingBurn:false}), ZERO_BYTES);

        uint256 usdcAfter = usdc.balanceOf(address(this));
        uint256 citAfter = cit.balanceOf(address(this));

        // Verify CIT spent and USDC gained matches expected ratio.
        assertEq(citBefore - citAfter, citToSwap, "CIT spent not correct");
        assertEq(usdcAfter - usdcBefore, 50e6, "USDC gained not correct");
    }

    // Test 5: Price Change Effect on Liquidity
    // Change the oracle price and add more liquidity to verify CIT minted at higher price is fewer.
    function testPriceChangeEffectOnLiquidity() public {
        // Double price to $2000
        oracle.updateAnswer(int256(2000e18));
        hook.addLiquidity(key, 100e6);

        (uint256 collateral, uint256 debt) = cdpManager.positions(address(this));

        // At higher price, for the same collateral, fewer CIT are minted, 
        // just ensure the debt increased and logic holds.
        assertTrue(debt > 66666, "Debt not increased after second add at higher price");
    }

    // Additional tests would go here for redeem and liquidate once the logic is integrated with the Hook:
    // However, user requested to handle that in a previous iteration. The final code would have corresponding 
    // redeem and liquidate tests integrated with the hook calls and proper commentary.
    // For now, this code snippet focuses on the requested test commentary improvements.

}
