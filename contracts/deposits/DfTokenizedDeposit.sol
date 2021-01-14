pragma solidity ^0.5.16;

import "@openzeppelin/upgrades/contracts/Initializable.sol";

import "../access/Adminable.sol";

import "./DfProfits.sol";

import "../utils/DSMath.sol";

import "../constants/ConstantAddressesMainnet.sol";

import "../compound/interfaces/ICToken.sol";
import "../interfaces/IDfFinanceDeposits.sol";
import "../interfaces/IToken.sol";
import "../interfaces/IDfDepositToken.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IDfInfo.sol";

interface IComptroller {
    function oracle() external view returns (IPriceOracle);
    function getAccountLiquidity(address) external view returns (uint, uint, uint);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function factory() external view returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}
interface IUniswapV2Pair {
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function sync() external;
}

interface IDefiController {
    function defiController() external view returns (address);
}

interface ITokenUSDT {
    function transfer(address to, uint value) external; // USDT don't return bool
}

contract DfTokenizedDeposit is
    Initializable,
    Adminable,
    DSMath,
    ConstantAddresses
{

    struct ProfitData {
        uint64 blockNumber;
        uint64 daiProfit; // div 1e12 (6 dec)
        uint64 usdtProfit;
    }

    ProfitData[] public profits;

    IDfDepositToken public token;
    address public dfWallet;

    mapping(address => uint64) public lastProfitDistIndex;

    address usdtExchanger;

    event CompSwap(uint256 timestamp, uint256 compPrice);
    event Profit(address indexed user, uint64 index, uint64 usdtProfit, uint64 daiProfit);

    mapping(address => bool) public approvedContracts; // mapping from old implementation

    // ----------------------------------------------------------------------------------------
    // all vars up to this line are used in Upgradable contract and shouldn't be changed\removed

    address public liquidityProviderAddress;

    // flash loan coefficient (supply: USER_FUNDS * (crate + 100), borrow: USER_FUNDS * crate, flashLoan: USER_FUNDS * crate)
    uint256 public crate;
    mapping(address => uint256) public fundsUnwinded;

    IDfFinanceDeposits public constant dfFinanceDeposits = IDfFinanceDeposits(0xFff9D7b0B6312ead0a1A993BF32f373449006F2F); // mainnet address

    IUniswapV2Router02 constant uniRouter = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D); // same for kovan and mainnet
    IDfInfo constant dfInfo = IDfInfo(0xee5aEb4314BF8C0A2f0A704305E599343480DbF1); // mainnet address
    address constant bridge = address(0x69c707d975e8d883920003CC357E556a4732CD03); // mainnet address 

    IDfDepositToken public tokenETH;
    IDfDepositToken public tokenUSDC;

    uint256 public rewardFee;
    uint256 public ethCoef;
    IDfFinanceDeposits.FlashloanProvider public providerType;
    uint256 public lastFixProfit;
    DfProfits constant dfProfits = DfProfits(0x65D4853d663CeE114A0aA1c946E95479C53e78c2); // contract that contains only profit funds

    event Credit(address token, uint256 amount);
    event SysCredit(uint256 amount);

    uint256 public totalDaiLoanForEth;

    function initialize() public initializer {
        address payable curOwner = 0xdAE0aca4B9B38199408ffaB32562Bf7B3B0495fE;
        Adminable.initialize(curOwner);  // Initialize Parent Contract

        IToken(DAI_ADDRESS).approve(address(dfFinanceDeposits), uint256(-1));
    }
    function setupTotalDaiLoanForEthOnce(uint256 newValue) public onlyOwner {
        require(totalDaiLoanForEth == 0);
        totalDaiLoanForEth = newValue;
    }

    function migrateToV2Once() public {
        require(tokenETH == IDfDepositToken(0x0) && tokenUSDC == IDfDepositToken(0x0) && rewardFee == 0 && crate == 0 && ethCoef == 0);
        crate = 290 * 1e18 / 100;
        ethCoef = 1e18 / 2;
        rewardFee = 20; // 20%
        tokenUSDC = IDfDepositToken(0x443A024a95a3Ae20b6aA59C93cc37bF7a3bEf7B2);
        tokenETH = IDfDepositToken(0xF145A9e7Edc6D5a27BBdd16E4E29F5Fe56671A22);
    }

    // fastDeposit used for low-fee deposit, function returns tokens left
    function fastDeposit(IDfDepositToken dTokenAddress, address assetAddress, uint256 amount) internal returns (uint256) {
        address _liquidityProviderAddress = liquidityProviderAddress;
        if (dTokenAddress.balanceOf(_liquidityProviderAddress) >= amount && dTokenAddress.allowance(_liquidityProviderAddress, address(this)) >= amount) {
            if (assetAddress == WETH_ADDRESS) {
                // transfer WETH because _liquidityProviderAddress uses WETH instead of ETH in burnTokenFast function
                IToken weth = IToken(WETH_ADDRESS);
                weth.deposit.value(amount)();
                weth.transfer(_liquidityProviderAddress, amount);
            } else {
                IToken(assetAddress).transferFrom(msg.sender, _liquidityProviderAddress, amount);
            }

            dTokenAddress.transferFrom(_liquidityProviderAddress, msg.sender, amount);
            return 0;
        }
        return amount;
    }

    // amounts[0] - DAI, amounts[1] - USDC, amounts[2] - ETH
    function deposit(uint256[] memory amounts, address flashloanFromAddress, IDfFinanceDeposits.FlashloanProvider _providerType) public payable {
        require(msg.sender == tx.origin  || approvedContracts[msg.sender]);
        amounts[2] = msg.value;

        // when dfWallet is 0, first user should deposit eth
        // require(dfWallet != address(0) || (amountETH > 0 && amountUSDC == 0 && amountDAI == 0));

        // fast deposit
        if (amounts[0] > 0) amounts[0] = fastDeposit(token, DAI_ADDRESS, amounts[0]);

        if (amounts[1] > 0) amounts[1] = fastDeposit(tokenUSDC, USDC_ADDRESS, amounts[1]);

        if (amounts[2] > 0) amounts[2] = fastDeposit(tokenETH, WETH_ADDRESS, amounts[2]);

        if (amounts[0] > 0 || amounts[1] > 0 || amounts[2] > 0)
        {
            uint256 flashLoanDAI;
            uint256 flashLoanUSDC;
            uint256 daiLoanForEth; // flash loan for 1 ETH
            (flashLoanDAI, flashLoanUSDC, daiLoanForEth) = getFlashLoanAmounts(amounts[0], amounts[1], amounts[2], true);

            // [0] - daiLiquidity, [1] - usdcLiquidity
            uint256 [] memory liquidity = new uint256[](2);
            if (_providerType == IDfFinanceDeposits.FlashloanProvider.AAVE) {
                if (flashLoanDAI > 0) {
                    liquidity[0] = ICToken(CDAI_ADDRESS).balanceOfUnderlying(dfWallet);
                }
                if (flashLoanUSDC > 0) {
                    liquidity[1] = ICToken(CUSDC_ADDRESS).balanceOfUnderlying(dfWallet);
                }
            }

            if (amounts[0] > 0) IToken(DAI_ADDRESS).transferFrom(msg.sender, address(dfWallet), amounts[0]);
            if (amounts[1] > 0) IToken(USDC_ADDRESS).transferFrom(msg.sender, address(dfWallet), amounts[1]);

            dfFinanceDeposits.deposit.value(amounts[2])(dfWallet, amounts[0], amounts[1], 0, flashLoanDAI, flashLoanUSDC, _providerType, flashloanFromAddress);

            if (_providerType == IDfFinanceDeposits.FlashloanProvider.AAVE) {
                if (flashLoanDAI > 0) {
                    uint256 currentLiquidityAfterFee = sub(ICToken(CDAI_ADDRESS).balanceOfUnderlying(dfWallet), amounts[0]);
                    if (liquidity[0] > currentLiquidityAfterFee) {
                        uint256 daiAaveFee = liquidity[0] - currentLiquidityAfterFee;
                        if (amounts[0] > daiAaveFee) {
                            amounts[0] -= daiAaveFee;
                        } else {
                            IPriceOracle compOracle = IComptroller(COMPTROLLER).oracle();
                            uint256 feeInEth = daiAaveFee * 1e12 / compOracle.price("ETH") / compOracle.price("DAI");
                            amounts[2] = sub(amounts[2], feeInEth);
                        }
                    }
                }
                if (flashLoanUSDC > 0) {
                    uint256 currentLiquidityAfterFee = sub(ICToken(CUSDC_ADDRESS).balanceOfUnderlying(dfWallet), amounts[1]);
                    if (liquidity[1] > currentLiquidityAfterFee) {
                        amounts[1] = sub(amounts[1], liquidity[1] - currentLiquidityAfterFee);
                    }

                }
            }

            if (amounts[0] > 0) token.mint(msg.sender, amounts[0]);
            if (amounts[1] > 0) tokenUSDC.mint(msg.sender, amounts[1]);
            if (amounts[2] > 0) tokenETH.mint(msg.sender, amounts[2]);

            uint256 totalDETH = sub(tokenETH.totalSupply(), amounts[2]);
            totalDaiLoanForEth = wdiv(add(wmul(totalDaiLoanForEth,totalDETH), daiLoanForEth), add(totalDETH, amounts[2]));
        }
    }

    function burnTokenFast(IDfDepositToken tokenDeposit, IToken targetAsset, uint256 amount, address _liquidityProviderAddress) internal returns (uint256) {
        uint256 _fundsUnwinded = fundsUnwinded[address(targetAsset)];
        // exchange tokens if required amount unwinded exists
        if (_fundsUnwinded >= amount) {
            tokenDeposit.burnFrom(msg.sender, amount);
            if (address(targetAsset) == WETH_ADDRESS) {
                address(uint160(msg.sender)).transfer(amount);
            } else {
                IToken(targetAsset).transfer(msg.sender, amount);
            }

            fundsUnwinded[address(targetAsset)] = sub(_fundsUnwinded, amount);
            return 0;
        } else {
            if (targetAsset.balanceOf(_liquidityProviderAddress) >= amount && targetAsset.allowance(_liquidityProviderAddress, address(this)) >= amount) {
                // exchnage tokens with low fee via liquidityProviderAddress
                tokenDeposit.transferFrom(msg.sender, _liquidityProviderAddress, amount);
                if (address(targetAsset) == WETH_ADDRESS) {
                    // WETH (this) => ETH (withdraw) => ETH (msg.sender)
                    targetAsset.transferFrom(_liquidityProviderAddress, address(this), amount);
                    IToken(WETH_ADDRESS).withdraw(amount);
                    address(uint160(msg.sender)).transfer(amount);
                } else {
                    targetAsset.transferFrom(_liquidityProviderAddress, msg.sender, amount);
                }
                return 0;
            } else {
                return amount;
            }
        }
    }

    function getFlashLoanAmounts(uint256 amountDAI, uint256 amountUSDC, uint256 amountETH, bool isDeposit) internal returns (uint256 flashLoanDAI, uint256 flashLoanUSDC, uint256 daiLoanForEth) {
        IPriceOracle compOracle = IComptroller(COMPTROLLER).oracle();
        uint256 _crate = crate;
        uint256 _ethCoef = ethCoef;
        require(_crate > 0 && _ethCoef > 0);
        uint256 _daiPrice = compOracle.price("DAI");
        flashLoanDAI = wmul(amountDAI, _crate);
        if (amountUSDC > 0) flashLoanUSDC = wmul(amountUSDC, _crate);
        if (amountETH > 0)  {
            if (isDeposit) {
                daiLoanForEth = wmul(wmul(amountETH * compOracle.price("ETH") * _daiPrice / 1e12, _ethCoef), (_crate + 1e18));
            } else {
                daiLoanForEth = wmul(totalDaiLoanForEth, amountETH);
            }

            flashLoanDAI += daiLoanForEth;
        }
    }

    function burnTokens(uint256 amountDAI, uint256 amountUSDC, uint256 amountETH, address flashLoanFromAddress, IDfFinanceDeposits.FlashloanProvider _providerType) public {
        require(msg.sender == tx.origin  || approvedContracts[msg.sender]);

        address _liquidityProviderAddress = liquidityProviderAddress;
        if (amountDAI > 0) amountDAI = burnTokenFast(token, IToken(DAI_ADDRESS), amountDAI, _liquidityProviderAddress);
        if (amountUSDC > 0) amountUSDC = burnTokenFast(tokenUSDC, IToken(USDC_ADDRESS), amountUSDC, _liquidityProviderAddress);
        if (amountETH > 0) amountETH = burnTokenFast(tokenETH, IToken(WETH_ADDRESS), amountETH, _liquidityProviderAddress);

        if (amountDAI > 0 || amountUSDC > 0 || amountETH > 0) {

            uint256 flashLoanDAI;
            uint256 flashLoanUSDC;
            (flashLoanDAI, flashLoanUSDC,) = getFlashLoanAmounts(amountDAI, amountUSDC, amountETH, false);

            dfFinanceDeposits.withdraw(dfWallet, amountDAI, amountUSDC, amountETH, 0, msg.sender, flashLoanDAI, flashLoanUSDC, _providerType, flashLoanFromAddress);

            if (amountDAI > 0) token.burnFrom(msg.sender, amountDAI);
            if (amountUSDC > 0) tokenUSDC.burnFrom(msg.sender, amountUSDC);
            if (amountETH > 0) tokenETH.burnFrom(msg.sender, amountETH);

            // TODO: check CRATE
        }
    }

    // wrapper-function for dai
    function burnTokens(uint256 amountDAI, bool useFlashLoan) public {
        burnTokens(amountDAI, 0, 0, address(0), providerType);
    }

    // amounts[0] - DAI amounts[1] - USDC amounts[2] - ETH
    function sync(IDfFinanceDeposits.FlashloanProvider _providerType, address flashLoanFromAddress, uint256 _newCRate, uint256 _newEthCoef, uint256[3] memory amounts, bool check) onlyOwnerOrAdmin public returns (uint256 avgCRate, uint256 avgEthCoef, uint256 f)  {
        IPriceOracle compOracle = IComptroller(COMPTROLLER).oracle();
        uint256 _daiPrice = compOracle.price("DAI") * 1e12;
        uint256 _ethPrice = compOracle.price("ETH") * 1e12;

        unwindFunds(amounts[0], amounts[1], amounts[2], _providerType, flashLoanFromAddress);

        { // fix "stack too deep"
            uint256 amountTotalETH = tokenETH.totalSupply();
            uint256 totalShare = wdiv(amounts[0] + wmul(amounts[1] * 1e12, _daiPrice) + wmul(wmul(wmul(amounts[2], ethCoef) , _ethPrice), _daiPrice),
                token.totalSupply() + wmul(tokenUSDC.totalSupply() * 1e12, _daiPrice) + wmul(wmul(wmul(amountTotalETH, ethCoef), _ethPrice), _daiPrice)
            );
            if (_newCRate > 100) {
                avgCRate = (crate * sub(1e18, totalShare) +  _newCRate * totalShare) / 1e18;
                crate = _newCRate;
            }
            if (_newEthCoef > 100) {
                uint256 shareEth = wdiv(amounts[2], amountTotalETH);
                avgEthCoef =  (ethCoef * sub(1e18, shareEth) +  _newEthCoef * shareEth) / 1e18;
                ethCoef = _newEthCoef;
            }
        }

        boostFunds(amounts[0], amounts[1], amounts[2], _providerType, flashLoanFromAddress);

        if (avgCRate > 0) crate = avgCRate;
        if (avgEthCoef > 0) ethCoef = avgEthCoef;

        if (check) {
            (,,,,f,,,) = dfInfo.getInfo(address(this));
        }
    }

    function unwindFunds(uint256 amountDAI, uint256 amountUSDC, uint256 amountETH, IDfFinanceDeposits.FlashloanProvider _providerType, address flashLoanFromAddress) public onlyOwnerOrAdmin {
        (uint256 flashLoanDAI, uint256 flashLoanUSDC,) = getFlashLoanAmounts(amountDAI, amountUSDC, amountETH, false);

        uint256 balanceDAI;
        uint256 balanceUSDC;
        if (amountDAI > 0) balanceDAI = IToken(DAI_ADDRESS).balanceOf(address(this));
        if (amountUSDC > 0) balanceUSDC = IToken(USDC_ADDRESS).balanceOf(address(this));
        dfFinanceDeposits.withdraw(dfWallet, amountDAI, amountUSDC, amountETH, 0, address(this), flashLoanDAI, flashLoanUSDC, _providerType, flashLoanFromAddress);

        if (amountDAI > 0) {
            balanceDAI = sub(IToken(DAI_ADDRESS).balanceOf(address(this)), balanceDAI);
            if (amountDAI > balanceDAI) emit Credit(DAI_ADDRESS, amountDAI - balanceDAI); // system lose via credit
            fundsUnwinded[DAI_ADDRESS] += amountDAI;
        }
        if (amountUSDC > 0) {
            balanceUSDC = sub(IToken(USDC_ADDRESS).balanceOf(address(this)), balanceUSDC);
            if (amountUSDC > balanceUSDC) emit Credit(USDC_ADDRESS, balanceUSDC - amountUSDC); // system lose via credit
            fundsUnwinded[USDC_ADDRESS] += amountUSDC;
        }
        if (amountETH > 0) {
            require(address(this).balance >= amountETH);
            fundsUnwinded[WETH_ADDRESS] += amountETH;
        }

    }

    function boostFunds(uint256 amountDAI, uint256 amountUSDC, uint256 amountETH, IDfFinanceDeposits.FlashloanProvider _providerType, address flashLoanFromAddress) public onlyOwnerOrAdmin  {
        if (amountDAI > fundsUnwinded[DAI_ADDRESS]) amountDAI = fundsUnwinded[DAI_ADDRESS];
        if (amountUSDC > fundsUnwinded[USDC_ADDRESS]) amountUSDC = fundsUnwinded[USDC_ADDRESS];
        if (amountETH > fundsUnwinded[WETH_ADDRESS]) amountETH = fundsUnwinded[WETH_ADDRESS];

        uint256 flashLoanDAI;
        uint256 flashLoanUSDC;
        uint256 daiLoanForEth; // flash loan for 1 ETH
        (flashLoanDAI, flashLoanUSDC, daiLoanForEth) = getFlashLoanAmounts(amountDAI, amountUSDC, amountETH, true);
        if (amountDAI  > 0)  IToken(DAI_ADDRESS).transfer(address(dfWallet), amountDAI);
        if (amountUSDC > 0)  IToken(USDC_ADDRESS).transfer(address(dfWallet), amountUSDC);
        dfFinanceDeposits.deposit.value(amountETH)(dfWallet, amountDAI, amountUSDC, 0, flashLoanDAI, flashLoanUSDC, _providerType, flashLoanFromAddress);
        if (amountDAI > 0) fundsUnwinded[DAI_ADDRESS] = sub(fundsUnwinded[DAI_ADDRESS], amountDAI);
        if (amountUSDC > 0) fundsUnwinded[USDC_ADDRESS] = sub(fundsUnwinded[USDC_ADDRESS], amountUSDC);
        if (amountETH > 0) fundsUnwinded[WETH_ADDRESS] = sub(fundsUnwinded[WETH_ADDRESS], amountETH);

        uint256 totalDETH = sub(tokenETH.totalSupply(), amountETH);
        totalDaiLoanForEth = wdiv(add(wmul(totalDaiLoanForEth, totalDETH), daiLoanForEth), add(totalDETH, amountETH));
    }

    uint256 constant snapshotOffset = 73; // offset for new tokens

    function userShare(address userAddress, uint256 snapshotId) view public returns (uint256 totalLiquidity, uint256 totalSupplay) {
        if (snapshotId == uint256(-1)) snapshotId = profits.length;

        totalLiquidity = token.balanceOfAt(userAddress, snapshotId);
        totalSupplay = token.totalSupplyAt(snapshotId);

        if (snapshotId > snapshotOffset) {
            uint256 newId = snapshotId - snapshotOffset;
            uint256 priceETH = tokenETH.prices(newId);

            totalLiquidity +=
            wmul(mul(tokenETH.balanceOfAt(userAddress, newId), priceETH) / 1e6, ethCoef) + // ETH price 6 decimals
            tokenUSDC.balanceOfAt(userAddress, newId) * 1e12;                              // USDC 6 decimals => 18, suggest 1 DAI == 1 USDC

            // totalSupplay for rewards distribution (we extract from eth `ethCoef`% DAI)
            totalSupplay +=
            wmul(mul(tokenETH.totalSupplyAt(newId), priceETH) / 1e6, ethCoef) +  // ETH price 6 decimals
            tokenUSDC.totalSupplyAt(newId) * 1e12;                               // USDC 6 decimals => 18
        }
    }

    function getUserProfitFromCustomIndex(address userAddress, uint64 fromIndex, uint256 max) public view returns(
        uint256 totalUsdtProfit, uint256 totalDaiProfit, uint64 index
    ) {
        if (profits.length < max) max = profits.length;

        index = fromIndex;

        for(; index < max; index++) {
            ProfitData memory p = profits[index];
            uint256 balanceAtBlock;
            uint256 totalSupplyAt;
            (balanceAtBlock, totalSupplyAt) = userShare(userAddress, index + 1);

            uint256 profitUsdt = wdiv(wmul(uint256(p.usdtProfit), balanceAtBlock), totalSupplyAt);
            uint256 profitDai = wdiv(wmul(mul(uint256(p.daiProfit), 1e12),balanceAtBlock), totalSupplyAt);
            totalUsdtProfit = add(totalUsdtProfit, profitUsdt);
            totalDaiProfit = add(totalDaiProfit, profitDai);
        }
    }

    function calcUserProfit(address userAddress, uint256 max) public view returns(
        uint256 totalUsdtProfit, uint256 totalDaiProfit, uint64 index
    ) {
        (totalUsdtProfit, totalDaiProfit, index) = getUserProfitFromCustomIndex(userAddress, lastProfitDistIndex[userAddress], max);
    }

    function sendRewardToUser(address _account, address _profitTo, uint64 _index, uint256 _totalUsdtProfit, uint256 _totalDaiProfit, bool _isReinvest) internal {
        lastProfitDistIndex[_account] = _index;

        // usdt rewards from old contract implementation
        if (_totalUsdtProfit > 0) {
            ITokenUSDT(USDT_ADDRESS).transfer(_profitTo, _totalUsdtProfit);
        }

        if (_totalDaiProfit > 0) {
            dfProfits.cast(address(uint160(DAI_ADDRESS)), abi.encodeWithSelector(IToken(DAI_ADDRESS).transfer.selector, _profitTo, _totalDaiProfit));
            if (_isReinvest) {
                uint256[] memory amounts = new uint256[](3);
                amounts[0] = _totalDaiProfit;
                deposit(amounts, address(0x0), providerType);
            }
        }
    }

    function getUniswapAddress() view public returns (address) {
        return IUniswapV2Factory(uniRouter.factory()).getPair(DAI_ADDRESS, address(token));
    }

    // claiming profit for uniswap pool
    function claimProfitForUniswap() public {
        require(msg.sender == tx.origin);

        uint64 index;
        uint256 totalDaiProfit;
        address _uniswapAddress = getUniswapAddress();
        (, totalDaiProfit, index) = calcUserProfit(_uniswapAddress, uint256(-1));

        lastProfitDistIndex[_uniswapAddress] = index;

        if (totalDaiProfit > 0) {
            dfProfits.cast(address(uint160(DAI_ADDRESS)), abi.encodeWithSelector(IToken(DAI_ADDRESS).transfer.selector, _uniswapAddress, totalDaiProfit));
            (uint reserveIn, uint reserveOut,) = IUniswapV2Pair(_uniswapAddress).getReserves();
            uint amountInWithFee = mul(totalDaiProfit / 2, 997);
            uint numerator = mul(amountInWithFee, reserveOut);
            uint denominator = add(mul(reserveIn, 1000), amountInWithFee);
            uint amountOut = numerator / denominator;
            IUniswapV2Pair(_uniswapAddress).swap(amountOut, 0, address(_uniswapAddress), new bytes(0));
            IUniswapV2Pair(_uniswapAddress).sync();
        }
    }

    function claimProfitForLockedOnBridge() public onlyOwnerOrAdmin {
        (uint256 totalUsdtProfit, uint256 totalDaiProfit, uint64 index) = calcUserProfit(bridge, uint256(-1));
        sendRewardToUser(bridge, msg.sender, index, totalUsdtProfit, totalDaiProfit, false);
    }

    function claimProfitForCustomContract(address _claimForAddress) public {
        (uint256 totalUsdtProfit, uint256 totalDaiProfit, uint64 index) = calcUserProfit(_claimForAddress, uint256(-1));
        address profitTo = IDefiController(_claimForAddress).defiController();
        sendRewardToUser(_claimForAddress, profitTo, index, totalUsdtProfit, totalDaiProfit, false);
    }

    function userClaimProfitOptimized(uint64 fromIndex, uint64 lastIndex, uint256 totalUsdtProfit, uint256 totalDaiProfit, uint8 v, bytes32 r, bytes32 s, bool isReinvest) public {
        address account = msg.sender;
        require(account == tx.origin);
        uint64 currentIndex = lastProfitDistIndex[account];
        require(currentIndex == fromIndex);

        // check signature
        uint256 versionNonce = 1;
        bytes32 hash = sha256(abi.encodePacked(this, versionNonce, account, fromIndex, lastIndex, totalUsdtProfit, totalDaiProfit));
        address src = ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)), v, r, s);
        require(admins[src] == true);

        require(currentIndex < lastIndex);

        sendRewardToUser(account, account, lastIndex, totalUsdtProfit, totalDaiProfit, isReinvest);
    }

    function userClaimProfit(uint64 max) public {
        address account = msg.sender;
        require(account == tx.origin);

        (uint256 totalUsdtProfit, uint256 totalDaiProfit, uint64 index) = calcUserProfit(account, max);

        sendRewardToUser(account, account, index, totalUsdtProfit, totalDaiProfit, false);
    }

    function getCompPriceInDAI() view public returns(uint256) {
        //  price not less that price from oracle with 5% slippage
        IPriceOracle compOracle = IComptroller(COMPTROLLER).oracle();
        return compOracle.price("COMP") * 1e18 / compOracle.price("DAI") * 95 / 100;
    }

    // profit in DAI
    function fixProfit() public returns (uint256) {
        require(msg.sender == tx.origin); // to prevent flash-loan attack
        require(now - lastFixProfit > 6 hours);
        address [] memory path = new address[](3);
        path[0] = COMP_ADDRESS;
        path[1] = WETH_ADDRESS;
        path[2] = DAI_ADDRESS;
        address [] memory ctokens = new address[](3);
        ctokens[0] = CDAI_ADDRESS;
        ctokens[1] = CETH_ADDRESS;
        ctokens[2] = CUSDC_ADDRESS;

        uint256 amount = dfFinanceDeposits.claimComps(dfWallet, ctokens);
        ProfitData memory p;
        p.blockNumber = uint64(block.number);

        if (IToken(COMP_ADDRESS).allowance(address(this), address(uniRouter)) != uint256(-1)) {
            IToken(COMP_ADDRESS).approve(address(uniRouter), uint256(-1));
        }

        uint256 balance = IToken(DAI_ADDRESS).balanceOf(address(dfProfits));
        uint256 minDaiFromSwap = wmul(getCompPriceInDAI(), amount);

        uniRouter.swapExactTokensForTokens(amount, minDaiFromSwap, path, address(dfProfits), now + 1000);

        uint256 _reward = sub(IToken(DAI_ADDRESS).balanceOf(address(dfProfits)), balance);

        {
            address _dfWallet = dfWallet;
            uint256 totalDDAI = token.totalSupply();
            uint256 totalLiquidity = sub(ICToken(CDAI_ADDRESS).balanceOfUnderlying(_dfWallet),ICToken(CDAI_ADDRESS).borrowBalanceCurrent(_dfWallet));
            if (totalDDAI > totalLiquidity) {
                uint256 sysCred = totalDDAI - totalLiquidity;
                if (_reward > sysCred) {
                    IToken   DAI = IToken(DAI_ADDRESS);
                    ICToken cDAI = ICToken(CDAI_ADDRESS);
                    if (DAI.allowance(address(this), CDAI_ADDRESS) != uint256(-1)) {
                        DAI.approve(CDAI_ADDRESS, uint(-1));
                    }
                    require(cDAI.mint(sysCred) == 0);
                    IToken(CDAI_ADDRESS).transfer(_dfWallet, cDAI.balanceOf(address(this)));

                    _reward = _reward - sysCred;
                    emit SysCredit(sysCred);
                }
            }
        }


        emit CompSwap(block.timestamp, wdiv(_reward, amount));

        uint256 _fee = _reward * rewardFee / 100;
        dfProfits.cast(address(uint160(DAI_ADDRESS)), abi.encodeWithSelector(IToken(DAI_ADDRESS).transfer.selector, owner, _fee));
        _reward = sub(_reward, _fee);
        p.daiProfit = uint64(_reward / 1e12); // reduce decimals to 1e6
        profits.push(p);

        token.snapshot();

        IPriceOracle compOracle = IComptroller(COMPTROLLER).oracle();
        if (address(tokenETH) != address(0x0)) tokenETH.snapshot(compOracle.price("ETH"));
        if (address(tokenUSDC) != address(0x0)) tokenUSDC.snapshot();

        lastFixProfit = now;
        return p.daiProfit;
    }

    function setLiquidityProviderAddress(address _newAddress) public onlyOwner {
        liquidityProviderAddress = _newAddress;
    }

    function setRewardFee(uint256 _newRewardFee) public onlyOwner {
        require(_newRewardFee < 50);
        rewardFee = _newRewardFee;
    }

    function changeEthCoef(uint256 _newCoef) public onlyOwnerOrAdmin {
        require(_newCoef < 2e18); // normal - 50% == 0.5 == 1e18 / 2
        ethCoef = _newCoef;
    }

    function changeCRate(uint256 _newRate) public onlyOwnerOrAdmin {
        // normal 2.9 == 290 * 1e18 / 100
        crate = _newRate;
    }


    function setProviderType(IDfFinanceDeposits.FlashloanProvider _newProviderType) public onlyOwnerOrAdmin {
        providerType = _newProviderType;
    }

    function setApprovedContract(address newContract, bool bActive) public onlyOwner {
        approvedContracts[newContract] = bActive;
    }

    // **FALLBACK functions**
    function() external payable {}
}
