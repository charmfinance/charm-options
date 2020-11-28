// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./libraries/ABDKMath64x64.sol";
import "./libraries/UniERC20.sol";
import "./libraries/openzeppelin/OwnableUpgradeSafe.sol";
import "./libraries/openzeppelin/ReentrancyGuardUpgradeSafe.sol";
import "../interfaces/IOracle.sol";
import "./OptionsToken.sol";


contract OptionMarket is ReentrancyGuardUpgradeSafe, OwnableUpgradeSafe {
    using Address for address;
    using SafeERC20 for IERC20;
    using UniERC20 for IERC20;
    using SafeMath for uint256;

    uint256 public constant SCALE = 1e18;
    uint256 public constant SCALE_SCALE = 1e36;

    IERC20 public baseToken;
    IOracle public oracle;
    OptionsToken[] public longTokens;
    OptionsToken[] public shortTokens;
    uint256[] public strikePrices;
    uint256 public expiryTime;
    uint256 public alpha;
    bool public isPut;
    uint256 public tradingFee;
    uint256 public balanceCap;
    uint256 public totalSupplyCap;

    uint256 public maxStrikePrice;
    uint256 public numStrikes;

    function initialize(
        address _baseToken,
        address _oracle,
        address[] memory _longTokens,
        address[] memory _shortTokens,
        uint256[] memory _strikePrices,
        uint256 _expiryTime,
        uint256 _alpha,
        bool _isPut,
        uint256 _tradingFee,
        uint256 _balanceCap,
        uint256 _totalSupplyCap
    ) public initializer {
        __ReentrancyGuard_init();
        __Ownable_init();

        require(_longTokens.length == _strikePrices.length, "Lengths do not match");
        require(_shortTokens.length == _strikePrices.length, "Lengths do not match");

        require(_strikePrices.length > 0, "Strike prices must not be empty");
        require(_strikePrices[0] > 0, "Strike prices must be > 0");
        for (uint256 i = 0; i < _strikePrices.length - 1; i++) {
            require(_strikePrices[i] < _strikePrices[i+1], "Strike prices must be increasing");
        }

        require(_alpha > 0, "Alpha must be > 0");
        require(_alpha < SCALE, "Alpha must be < 1");
        require(_tradingFee < SCALE, "Trading fee must be < 1");
        require(_balanceCap > 0, "Balance cap must be > 0");
        require(_totalSupplyCap > 0, "Total supply cap must be > 0");

        baseToken = IERC20(_baseToken);
        oracle = IOracle(_oracle);
        strikePrices = _strikePrices;
        expiryTime = _expiryTime;
        alpha = _alpha;
        isPut = _isPut;
        tradingFee = _tradingFee;
        balanceCap = _balanceCap;
        totalSupplyCap = _totalSupplyCap;

        for (uint256 i = 0; i < _longTokens.length; i++) {
            longTokens.push(OptionsToken(_longTokens[i]));
        }

        for (uint256 i = 0; i < _shortTokens.length; i++) {
            shortTokens.push(OptionsToken(_shortTokens[i]));
        }

        maxStrikePrice = _strikePrices[_strikePrices.length - 1];
        numStrikes = _strikePrices.length;

        require(!isExpired(), "Already expired");
    }

    function buy(
        bool isLong,
        uint256 index,
        uint256 optionsOut,
        uint256 maxAmountIn
    ) external payable nonReentrant returns (uint256 amountIn) {
        require(!isExpired(), "Already expired");
        require(index < numStrikes, "Index too large");
        require(optionsOut > 0, "optionsOut must be > 0");

        uint256 costBefore = calcCost();
        OptionsToken option = isLong ? longTokens[index] : shortTokens[index];
        option.mint(msg.sender, optionsOut);
        require(option.balanceOf(msg.sender) < balanceCap, "Exceeded balance cap");
        require(option.totalSupply() < totalSupplyCap, "Exceeded total supply cap");

        uint256 costDiff = calcCost().sub(costBefore);
        uint256 fee = optionsOut.mul(tradingFee);
        if (isPut) {
            costDiff = costDiff.mul(maxStrikePrice).div(SCALE);
            fee = fee.mul(strikePrices[index]).div(SCALE);
        }
        amountIn = (costDiff.add(fee)).div(SCALE);
        require(amountIn > 0, "Amount in must be > 0");
        require(amountIn <= maxAmountIn, "Max slippage exceeded");

        uint256 balanceBefore = baseToken.uniBalanceOf(address(this));
        baseToken.uniTransferFromSenderToThis(amountIn);
        uint256 balanceAfter = baseToken.uniBalanceOf(address(this));
        require(baseToken.isETH() || balanceAfter.sub(balanceBefore) == amountIn, "Deflationary tokens not supported");
    }

    function sell(
        bool isLong,
        uint256 index,
        uint256 optionsIn,
        uint256 minAmountOut
    ) external nonReentrant returns (uint256 amountOut) {
        require(!isExpired(), "Already expired");
        require(index < numStrikes, "Index too large");
        require(optionsIn > 0, "optionsIn must be > 0");

        uint256 costBefore = calcCost();
        OptionsToken option = isLong ? longTokens[index] : shortTokens[index];
        option.burn(msg.sender, optionsIn);

        uint256 costDiff = costBefore.sub(calcCost());
        uint256 fee = optionsIn.mul(tradingFee);
        if (isPut) {
            costDiff = costDiff.mul(maxStrikePrice).div(SCALE);
            fee = fee.mul(strikePrices[index]).div(SCALE);
        }
        amountOut = (costDiff.sub(fee)).div(SCALE);
        require(amountOut > 0, "Amount in must be > 0");
        require(amountOut >= minAmountOut, "Max slippage exceeded");

        baseToken.uniTransfer(msg.sender, amountOut);
        return amountOut;
    }

    function calcCost() public view returns (uint256) {

        // initally set s to total supply of longs
        uint256 s;
        for (uint256 i = 0; i < numStrikes; i++) {
            s = s.add(longTokens[i].totalSupply());
        }

        // q[i] is total supply of longs[:i] and shorts[i:]
        uint256[] memory q = new uint256[](numStrikes + 1);
        q[0] = s;
        uint256 max = s;
        uint256 sum = s;

        // s keeps track of running sum
        for (uint256 i = 0; i < numStrikes; i++) {
            s = s.add(shortTokens[i].totalSupply());
            s = s.sub(longTokens[i].totalSupply());
            q[i+1] = s;
            max = Math.max(max, s);
            sum = sum.add(s);
        }

        // no options bought yet
        if (sum == 0) {
            return 0;
        }

        uint256 b = sum.mul(alpha);
        int128 sumExp;
        for (uint256 i = 0; i < q.length; i++) {

            // max(q) - q_i
            uint256 diff = max.sub(q[i]);

            // (max(q) - q_i) / b
            int128 div = ABDKMath64x64.divu(diff.mul(SCALE), b);

            // exp((q_i - max(q)) / b)
            int128 exp = ABDKMath64x64.exp(ABDKMath64x64.neg(div));
            sumExp = ABDKMath64x64.add(sumExp, exp);
        }

        // log(sumExp)
        int128 log = ABDKMath64x64.ln(sumExp);

        // b * log(sumExp) + max(q)
        return ABDKMath64x64.mulu(log, b).add(max.mul(SCALE));
    }

    function isExpired() public view returns (bool) {
        return block.timestamp >= expiryTime;
    }
}