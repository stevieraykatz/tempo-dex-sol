// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.24;

import { IStablecoinDEX } from "tempo-std/interfaces/IStablecoinDEX.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

/// @title StablecoinDEX (Solidity reading port)
/// @notice Solidity rendering of Tempo's StablecoinDEX precompile at 0xDEc0…0000, written for
/// reading, not deployment. Behaviour follows the Rust precompile at the latest hardfork; pre-fork
/// code paths are dropped. See README.md for what is and isn't modelled.
///
/// The DEX is a central limit order book per (base, quote) pair. Every TIP-20 has exactly one
/// quote token, so pairs form a tree rooted at pathUSD and multi-hop swaps route through the
/// lowest common ancestor. Prices are ticks of 0.1 bp around 1.0 (tick 0 = price 1.00000).
contract StablecoinDEX is IStablecoinDEX {

    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    ITIP20Factory internal constant TIP20_FACTORY =
        ITIP20Factory(0x20Fc000000000000000000000000000000000000);
    ITIP403Registry internal constant TIP403_REGISTRY =
        ITIP403Registry(0x403c000000000000000000000000000000000000);
    bytes12 internal constant TIP20_PREFIX = 0x20c000000000000000000000;

    int16 public constant override MIN_TICK = -2000;
    int16 public constant override MAX_TICK = 2000;
    int16 public constant override TICK_SPACING = 10;
    uint32 public constant override PRICE_SCALE = 100_000;
    uint32 public constant override MIN_PRICE = 98_000;
    uint32 public constant override MAX_PRICE = 102_000;
    /// 100 units of a 6-decimal token.
    uint128 public constant override MIN_ORDER_AMOUNT = 100_000_000;

    /// Sentinel best ticks for an empty side.
    int16 internal constant NO_BID = type(int16).min;
    int16 internal constant NO_ASK = type(int16).max;

    /// A result from a uint256 -> uint128 conversion that doesn't fit.
    error Overflow();

    struct Orderbook {
        address base;
        address quote;
        mapping(int16 tick => TickLevel) bids;
        mapping(int16 tick => TickLevel) asks;
        int16 bestBidTick;
        int16 bestAskTick;
        /// Index into `bookKeys` plus one; zero means unset. The precompile packs this into order
        /// records in place of the 32-byte book key.
        uint32 bookId;
        /// One bit per tick, 256 ticks per word, keyed by `tick >> 8`.
        mapping(int16 word => uint256) bidBitmap;
        mapping(int16 word => uint256) askBitmap;
    }

    /// Per-order arithmetic shared by swaps and quotes so the two always agree.
    struct Step {
        /// Base filled from this order. Below `order.remaining` means this order ends the trade.
        uint128 fillAmount;
        /// Added to the running total: taker output for exact-in, taker input for exact-out.
        uint128 accumulate;
        /// Input (exact-in) or output (exact-out) still owed after fully consuming this order.
        uint128 nextAmount;
    }

    struct Hop {
        bytes32 bookKey;
        /// True when the taker sells base into bids, false when buying base from asks.
        bool baseForQuote;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // Declared in the precompile's slot order. Order records differ physically: the precompile
    // writes a packed layout (no orderId, book index instead of book key).

    mapping(bytes32 pairKey => Orderbook) internal _books;
    mapping(uint128 orderId => Order) internal orders;
    /// Internal DEX balances: escrow refunds, fill proceeds, and funds a maker leaves on the DEX.
    mapping(address user => mapping(address token => uint128)) internal balances;
    uint128 internal _nextOrderId;
    bytes32[] internal bookKeys;
    mapping(address user => uint64) internal _storageCredits;

    /*//////////////////////////////////////////////////////////////
                             PRICE MATH
    //////////////////////////////////////////////////////////////*/

    function tickToPrice(int16 tick) public pure returns (uint32) {
        if (tick % TICK_SPACING != 0) revert InvalidTick();
        return _price(tick);
    }

    function priceToTick(uint32 price) public pure returns (int16 tick) {
        unchecked {
            tick = int16(int32(price) - int32(PRICE_SCALE));
        }
        if (price < MIN_PRICE || price > MAX_PRICE) revert TickOutOfBounds(tick);
        if (tick % TICK_SPACING != 0) revert InvalidTick();
    }

    function _price(int16 tick) internal pure returns (uint32) {
        return uint32(int32(PRICE_SCALE) + int32(tick));
    }

    /// base * price / PRICE_SCALE
    function _baseToQuote(uint128 base, int16 tick, bool roundUp) internal pure returns (uint128) {
        uint256 n = uint256(base) * _price(tick);
        return _u128(roundUp ? _divCeil(n, PRICE_SCALE) : n / PRICE_SCALE);
    }

    /// quote * PRICE_SCALE / price
    function _quoteToBase(uint128 quote, int16 tick, bool roundUp) internal pure returns (uint128) {
        uint256 n = uint256(quote) * PRICE_SCALE;
        uint256 p = _price(tick);
        return _u128(roundUp ? _divCeil(n, p) : n / p);
    }

    /// What the taker receives for `fill` base of an order: quote rounded down when selling into
    /// a bid, the base itself when buying from an ask.
    function _takerOutput(uint128 fill, int16 tick, bool orderIsBid) internal pure returns (uint128) {
        return orderIsBid ? _baseToQuote(fill, tick, false) : fill;
    }

    /*//////////////////////////////////////////////////////////////
                                 PAIRS
    //////////////////////////////////////////////////////////////*/

    /// keccak256(abi.encodePacked(base, quote)); argument order matters.
    function pairKey(address tokenA, address tokenB) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenA, tokenB));
    }

    function createPair(address base) external returns (bytes32) {
        return _createPair(base);
    }

    function _createPair(address base) internal returns (bytes32 key) {
        if (!TIP20_FACTORY.isTIP20(base)) revert InvalidBaseToken();
        address quote = _quoteOf(base);
        _requireUSD(base);
        _requireUSD(quote);

        key = pairKey(base, quote);
        Orderbook storage book = _books[key];
        if (book.base != address(0)) revert PairAlreadyExists();

        book.base = base;
        book.quote = quote;
        book.bestBidTick = NO_BID;
        book.bestAskTick = NO_ASK;
        book.bookId = uint32(bookKeys.length) + 1;
        bookKeys.push(key);

        emit PairCreated(key, base, quote);
    }

    /*//////////////////////////////////////////////////////////////
                             PLACE ORDERS
    //////////////////////////////////////////////////////////////*/

    function place(
        address token,
        uint128 amount,
        bool isBid,
        int16 tick
    )
        external
        returns (uint128)
    {
        return _place(msg.sender, token, amount, isBid, tick, false, 0);
    }

    /// A flip order re-posts itself on the opposite side at `flipTick` each time it fully fills,
    /// funded from the proceeds of the fill. A bid's flipTick must be >= tick and an ask's <= tick,
    /// so the proceeds always cover the new escrow.
    function placeFlip(
        address token,
        uint128 amount,
        bool isBid,
        int16 tick,
        int16 flipTick
    )
        external
        returns (uint128)
    {
        return _place(msg.sender, token, amount, isBid, tick, true, flipTick);
    }

    function _place(
        address maker,
        address base,
        uint128 amount,
        bool isBid,
        int16 tick,
        bool isFlip,
        int16 flipTick
    )
        internal
        returns (uint128 orderId)
    {
        address quote = _quoteOf(base);
        bytes32 key = pairKey(base, quote);
        if (_books[key].base == address(0)) _createPair(base);

        if (tick < MIN_TICK || tick > MAX_TICK) revert TickOutOfBounds(tick);
        if (tick % TICK_SPACING != 0) revert InvalidTick();
        if (isFlip) {
            if (flipTick < MIN_TICK || flipTick > MAX_TICK) revert TickOutOfBounds(flipTick);
            if (flipTick % TICK_SPACING != 0) revert InvalidFlipTick();
            if (isBid ? flipTick < tick : flipTick > tick) revert InvalidFlipTick();
        }
        if (amount < MIN_ORDER_AMOUNT) revert BelowMinimumOrderSize(amount);

        (address escrowToken, uint128 escrowAmount, address payoutToken) =
            _escrowFor(base, quote, amount, isBid, tick);

        // The maker must be able to receive the payout token. Fills credit it internally, which
        // bypasses TIP-20's pause check, so pause is checked here instead.
        _ensureTransferAuthorized(payoutToken, address(this), maker);
        _ensureNotPaused(payoutToken);

        _debitOrPull(maker, escrowToken, escrowAmount, true);

        orderId = nextOrderId();
        _nextOrderId = orderId + 1;

        _commitOrderToBook(
            Order({
                orderId: orderId,
                maker: maker,
                bookKey: key,
                isBid: isBid,
                tick: tick,
                amount: amount,
                remaining: amount,
                prev: 0,
                next: 0,
                isFlip: isFlip,
                flipTick: flipTick
            })
        );

        emit OrderPlaced(orderId, maker, base, amount, isBid, tick, isFlip, flipTick);
    }

    /// Bids escrow quote (rounded up), asks escrow base.
    function _escrowFor(
        address base,
        address quote,
        uint128 amount,
        bool isBid,
        int16 tick
    )
        internal
        pure
        returns (address escrowToken, uint128 escrowAmount, address payoutToken)
    {
        if (!isBid) return (base, amount, quote);
        uint256 q = _divCeil(uint256(amount) * _price(tick), PRICE_SCALE);
        if (q > type(uint128).max) revert InsufficientBalance();
        return (quote, uint128(q), base);
    }

    /// Appends the order to the FIFO queue at its tick.
    function _commitOrderToBook(Order memory order) internal {
        Orderbook storage book = _books[order.bookKey];
        TickLevel storage level = _level(book, order.tick, order.isBid);

        uint128 prevTail = level.tail;
        if (prevTail == 0) {
            level.head = order.orderId;
            level.tail = order.orderId;
            _setTickBit(book, order.tick, order.isBid);
            if (order.isBid) {
                if (order.tick > book.bestBidTick) book.bestBidTick = order.tick;
            } else if (order.tick < book.bestAskTick) {
                book.bestAskTick = order.tick;
            }
        } else {
            orders[prevTail].next = order.orderId;
            order.prev = prevTail;
            level.tail = order.orderId;
        }

        orders[order.orderId] = order;
    }

    /*//////////////////////////////////////////////////////////////
                           CANCEL / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function cancel(uint128 orderId) external {
        Order memory order = orders[orderId];
        if (order.maker == address(0)) revert OrderDoesNotExist();
        if (order.maker != msg.sender) revert Unauthorized();
        if (order.remaining == 0) revert OrderDoesNotExist();
        _cancelActive(order);
    }

    /// Anyone may cancel an order whose maker the token policies no longer allow to send the
    /// escrow token or receive the payout token.
    function cancelStaleOrder(uint128 orderId) external {
        Order memory order = orders[orderId];
        if (order.maker == address(0)) revert OrderDoesNotExist();
        if (_isMakerAuthorized(order)) revert OrderNotStale();
        _cancelActive(order);
    }

    function _isMakerAuthorized(Order memory order) internal view returns (bool) {
        Orderbook storage book = _books[order.bookKey];
        (address escrowToken, address payoutToken) =
            order.isBid ? (book.quote, book.base) : (book.base, book.quote);
        return _isAuthorizedOrFalse(escrowToken, order.maker, true)
            && _isAuthorizedOrFalse(payoutToken, order.maker, false);
    }

    /// Unlinks the order, refunds its remaining escrow to the maker's DEX balance, and deletes it.
    function _cancelActive(Order memory order) internal {
        Orderbook storage book = _books[order.bookKey];
        TickLevel storage level = _level(book, order.tick, order.isBid);

        if (order.prev != 0) orders[order.prev].next = order.next;
        else level.head = order.next;
        if (order.next != 0) orders[order.next].prev = order.prev;
        else level.tail = order.prev;

        if (level.head == 0) {
            _clearTickBit(book, order.tick, order.isBid);
            int16 best = order.isBid ? book.bestBidTick : book.bestAskTick;
            if (best == order.tick) _advanceBestTick(book, order.tick, order.isBid);
        }

        if (order.isBid) {
            balances[order.maker][book.quote] += _baseToQuote(order.remaining, order.tick, true);
        } else {
            balances[order.maker][book.base] += order.remaining;
        }

        delete orders[order.orderId];
        emit OrderCancelled(order.orderId);
    }

    function withdraw(address token, uint128 amount) external {
        uint128 balance = balances[msg.sender][token];
        if (balance < amount) revert InsufficientBalance();
        balances[msg.sender][token] = balance - amount;
        ITIP20(token).transfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 SWAPS
    //////////////////////////////////////////////////////////////*/

    function swapExactAmountIn(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 minAmountOut
    )
        external
        returns (uint128 amount)
    {
        Hop[] memory route = _findTradePath(tokenIn, tokenOut);
        // Route tokens were pause-checked in _findTradePath.
        _debitOrPull(msg.sender, tokenIn, amountIn, false);

        // Intermediate hop amounts never leave the DEX.
        amount = amountIn;
        for (uint256 i = 0; i < route.length; i++) {
            amount = _fillHop(route[i], amount, true, msg.sender);
        }
        if (amount < minAmountOut) revert InsufficientOutput();

        ITIP20(tokenOut).transfer(msg.sender, amount);
    }

    function swapExactAmountOut(
        address tokenIn,
        address tokenOut,
        uint128 amountOut,
        uint128 maxAmountIn
    )
        external
        returns (uint128 amount)
    {
        Hop[] memory route = _findTradePath(tokenIn, tokenOut);

        // Walk backwards from the output to find the input each hop needs.
        amount = amountOut;
        for (uint256 i = route.length; i > 0; i--) {
            amount = _fillHop(route[i - 1], amount, false, msg.sender);
        }
        if (amount > maxAmountIn) revert MaxInputExceeded();

        _debitOrPull(msg.sender, tokenIn, amount, false);
        ITIP20(tokenOut).transfer(msg.sender, amountOut);
    }

    function quoteSwapExactAmountIn(
        address tokenIn,
        address tokenOut,
        uint128 amountIn
    )
        external
        view
        returns (uint128 amount)
    {
        Hop[] memory route = _findTradePath(tokenIn, tokenOut);
        amount = amountIn;
        for (uint256 i = 0; i < route.length; i++) {
            amount = _quoteHop(route[i], amount, true);
        }
    }

    function quoteSwapExactAmountOut(
        address tokenIn,
        address tokenOut,
        uint128 amountOut
    )
        external
        view
        returns (uint128 amount)
    {
        Hop[] memory route = _findTradePath(tokenIn, tokenOut);
        amount = amountOut;
        for (uint256 i = route.length; i > 0; i--) {
            amount = _quoteHop(route[i - 1], amount, false);
        }
    }

    /// Fills resting orders on one book, best price first, FIFO within a tick, until `amount` is
    /// used up. Returns output for exact-in, input for exact-out.
    function _fillHop(
        Hop memory hop,
        uint128 amount,
        bool exactIn,
        address taker
    )
        internal
        returns (uint128 total)
    {
        bool isBid = hop.baseForQuote;
        Order memory order = _bestOrder(hop.bookKey, isBid);

        while (amount > 0) {
            Step memory s =
                exactIn ? _stepExactIn(amount, order, isBid) : _stepExactOut(amount, order, isBid);

            if (s.fillAmount < order.remaining) {
                _partialFill(order, s.fillAmount, taker);
                total += s.accumulate;
                break;
            }

            (bool hasNext, Order memory next) = _fillOrder(hop.bookKey, order, taker);
            total += s.accumulate;
            if (!hasNext) {
                if (s.nextAmount > 0) revert InsufficientLiquidity();
                break;
            }
            order = next;
            amount = s.nextAmount;
        }
    }

    /// Read-only twin of _fillHop: same steps, same traversal, no settlement.
    function _quoteHop(
        Hop memory hop,
        uint128 amount,
        bool exactIn
    )
        internal
        view
        returns (uint128 total)
    {
        bool isBid = hop.baseForQuote;
        Order memory order = _bestOrder(hop.bookKey, isBid);

        while (amount > 0) {
            Step memory s =
                exactIn ? _stepExactIn(amount, order, isBid) : _stepExactOut(amount, order, isBid);
            total += s.accumulate;
            if (s.fillAmount < order.remaining) break;

            (bool hasNext, Order memory next) = _orderAfter(hop.bookKey, order, isBid);
            if (!hasNext) {
                if (s.nextAmount > 0) revert InsufficientLiquidity();
                break;
            }
            order = next;
            amount = s.nextAmount;
        }
    }

    // `isBid` is the route's side; `order.isBid` is used for payouts. They match on any valid book.

    function _stepExactIn(
        uint128 amountIn,
        Order memory order,
        bool isBid
    )
        internal
        pure
        returns (Step memory s)
    {
        uint128 remaining = order.remaining;
        if (isBid) {
            // Taker sells base.
            s.fillAmount = _min(amountIn, remaining);
            s.nextAmount = amountIn > remaining ? amountIn - remaining : 0;
        } else {
            // Taker pays quote for base; base out rounds down, quote consumed rounds up.
            uint128 baseOut = _quoteToBase(amountIn, order.tick, false);
            s.fillAmount = _min(baseOut, remaining);
            s.nextAmount =
                baseOut > remaining ? amountIn - _baseToQuote(remaining, order.tick, true) : 0;
        }
        s.accumulate = _takerOutput(s.fillAmount, order.tick, order.isBid);
    }

    function _stepExactOut(
        uint128 amountOut,
        Order memory order,
        bool isBid
    )
        internal
        pure
        returns (Step memory s)
    {
        uint128 remaining = order.remaining;
        uint128 demand;
        if (isBid) {
            // Taker wants quote; base needed rounds up.
            demand = _quoteToBase(amountOut, order.tick, true);
            s.fillAmount = _min(demand, remaining);
            s.accumulate = s.fillAmount;
        } else {
            // Taker wants base; quote paid rounds up.
            demand = amountOut;
            s.fillAmount = _min(amountOut, remaining);
            s.accumulate = _baseToQuote(s.fillAmount, order.tick, true);
        }
        if (demand > remaining) {
            s.nextAmount = amountOut - _takerOutput(remaining, order.tick, order.isBid);
        }
    }

    function _partialFill(Order memory order, uint128 fill, address taker) internal {
        orders[order.orderId].remaining = order.remaining - fill;
        _creditMaker(order, fill);
        emit OrderFilled(order.orderId, order.maker, taker, fill, true);
    }

    /// Fully fills `order`, flips or deletes it, and returns the next order on the same side.
    /// Maker transfer policy is not checked here so a blocked maker can't halt swaps on the pair;
    /// cancelStaleOrder removes such orders.
    function _fillOrder(
        bytes32 key,
        Order memory order,
        address taker
    )
        internal
        returns (bool hasNext, Order memory next)
    {
        Orderbook storage book = _books[key];

        _creditMaker(order, order.remaining);
        emit OrderFilled(order.orderId, order.maker, taker, order.remaining, false);

        // A flip rewrites the record under the same orderId. A failed flip doesn't block the swap.
        bool flipped;
        if (order.isFlip) {
            try this.selfFlipInPlace(order) {
                flipped = true;
            } catch (bytes memory reason) {
                // No selector means out-of-gas or similar: propagate.
                if (reason.length < 4) {
                    assembly {
                        revert(add(reason, 32), mload(reason))
                    }
                }
                emit FlipFailed(order.orderId, order.maker, bytes4(reason));
            }
        }
        if (!flipped) delete orders[order.orderId];

        TickLevel storage level = _level(book, order.tick, order.isBid);
        if (order.next != 0) {
            level.head = order.next;
            orders[order.next].prev = 0;
            return (true, orders[order.next]);
        }

        // Tick exhausted.
        delete level.head;
        delete level.tail;
        _clearTickBit(book, order.tick, order.isBid);
        (int16 nextTick, bool found) = _advanceBestTick(book, order.tick, order.isBid);
        if (!found) return (false, next);
        return (true, orders[_level(book, nextTick, order.isBid).head]);
    }

    /// Self-call target so a failing flip reverts only its own state changes, as the precompile's
    /// storage checkpoint does.
    function selfFlipInPlace(Order memory order) external {
        if (msg.sender != address(this)) revert Unauthorized();

        Orderbook storage book = _books[order.bookKey];
        Order memory f = Order({
            orderId: order.orderId,
            maker: order.maker,
            bookKey: order.bookKey,
            isBid: !order.isBid,
            tick: order.flipTick,
            amount: order.amount,
            remaining: order.amount,
            prev: 0,
            next: 0,
            isFlip: true,
            flipTick: order.tick
        });

        (address escrowToken, uint128 escrowAmount, address payoutToken) =
            _escrowFor(book.base, book.quote, f.amount, f.isBid, f.tick);

        // Escrow comes only from the maker's DEX balance, never their wallet.
        uint128 balance = balances[f.maker][escrowToken];
        if (balance < escrowAmount) revert InsufficientBalance();
        _ensureNotPaused(escrowToken);
        _ensureTransferAuthorized(escrowToken, f.maker, address(this));
        _ensureNotPaused(payoutToken);
        _ensureTransferAuthorized(payoutToken, address(this), f.maker);
        balances[f.maker][escrowToken] = balance - escrowAmount;

        _commitOrderToBook(f);

        emit OrderFlipped(f.orderId, f.maker, book.base, f.amount, f.isBid, f.tick, f.flipTick);
    }

    /// Bid makers receive base exactly; ask makers receive quote rounded up.
    function _creditMaker(Order memory order, uint128 fill) internal {
        Orderbook storage book = _books[order.bookKey];
        if (order.isBid) {
            balances[order.maker][book.base] += fill;
        } else {
            balances[order.maker][book.quote] += _baseToQuote(fill, order.tick, true);
        }
    }

    function _bestOrder(bytes32 key, bool isBid) internal view returns (Order memory) {
        Orderbook storage book = _books[key];
        int16 tick = isBid ? book.bestBidTick : book.bestAskTick;
        if (tick == (isBid ? NO_BID : NO_ASK)) revert InsufficientLiquidity();
        return orders[_level(book, tick, isBid).head];
    }

    /// The order a swap would reach after fully consuming `order`, without changing state.
    function _orderAfter(
        bytes32 key,
        Order memory order,
        bool isBid
    )
        internal
        view
        returns (bool, Order memory next)
    {
        if (order.next != 0) return (true, orders[order.next]);
        Orderbook storage book = _books[key];
        (int16 tick, bool found) = _nextInitializedTick(book, order.tick, isBid);
        if (!found) return (false, next);
        return (true, orders[_level(book, tick, isBid).head]);
    }

    /// Debits the user's DEX balance, pulling any shortfall from their wallet.
    function _debitOrPull(address user, address token, uint128 amount, bool checkPause) internal {
        _ensureTransferAuthorized(token, user, address(this));
        uint128 balance = balances[user][token];
        if (balance >= amount) {
            // No TIP-20 transfer runs, so nothing else checks pause.
            if (checkPause) _ensureNotPaused(token);
            balances[user][token] = balance - amount;
        } else {
            // The precompile calls TIP-20 systemTransferFrom, which needs no allowance for the DEX.
            ITIP20(token).transferFrom(user, address(this), amount - balance);
            balances[user][token] = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                           MULTI-HOP ROUTING
    //////////////////////////////////////////////////////////////*/

    /// Path is tokenIn -> ... -> LCA -> ... -> tokenOut through the quote-token tree.
    function _findTradePath(
        address tokenIn,
        address tokenOut
    )
        internal
        view
        returns (Hop[] memory)
    {
        if (tokenIn == tokenOut) revert IdenticalTokens();
        if (!_hasTIP20Prefix(tokenIn) || !_hasTIP20Prefix(tokenOut)) revert InvalidToken();

        if (_quoteOf(tokenIn) == tokenOut || _quoteOf(tokenOut) == tokenIn) {
            address[] memory direct = new address[](2);
            direct[0] = tokenIn;
            direct[1] = tokenOut;
            return _buildRoute(direct);
        }

        address[] memory pathIn = _pathToRoot(tokenIn);
        address[] memory pathOut = _pathToRoot(tokenOut);

        // LCA: first token on tokenIn's path that is also on tokenOut's.
        uint256 lcaIn = type(uint256).max;
        uint256 lcaOut;
        for (uint256 i = 0; i < pathIn.length && lcaIn == type(uint256).max; i++) {
            for (uint256 j = 0; j < pathOut.length; j++) {
                if (pathIn[i] == pathOut[j]) {
                    (lcaIn, lcaOut) = (i, j);
                    break;
                }
            }
        }
        if (lcaIn == type(uint256).max) revert PairDoesNotExist();

        address[] memory path = new address[](lcaIn + 1 + lcaOut);
        for (uint256 i = 0; i <= lcaIn; i++) {
            path[i] = pathIn[i];
        }
        for (uint256 j = 0; j < lcaOut; j++) {
            path[lcaIn + 1 + j] = pathOut[lcaOut - 1 - j];
        }
        return _buildRoute(path);
    }

    /// Resolves each adjacent token pair to a book and direction, and rejects paused tokens.
    /// TIP-403 policy applies only to the taker's input and output, not intermediate tokens.
    function _buildRoute(address[] memory path) internal view returns (Hop[] memory route) {
        route = new Hop[](path.length - 1);
        for (uint256 i = 0; i + 1 < path.length; i++) {
            (address hopIn, address hopOut) = (path[i], path[i + 1]);
            _ensureNotPaused(hopIn);

            address base;
            address quote;
            if (_quoteOf(hopIn) == hopOut) (base, quote) = (hopIn, hopOut);
            else if (_quoteOf(hopOut) == hopIn) (base, quote) = (hopOut, hopIn);
            else revert PairDoesNotExist();

            bytes32 key = pairKey(base, quote);
            if (_books[key].base == address(0)) revert PairDoesNotExist();
            route[i] = Hop({ bookKey: key, baseForQuote: hopIn == base });
        }
    }

    /// [token, token.quoteToken(), ..., pathUSD]
    function _pathToRoot(address token) internal view returns (address[] memory path) {
        uint256 length = 1;
        for (address t = token; t != PATH_USD; t = _quoteOf(t)) {
            length++;
        }
        path = new address[](length);
        path[0] = token;
        for (uint256 i = 1; i < length; i++) {
            path[i] = _quoteOf(path[i - 1]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             TICK BITMAP
    //////////////////////////////////////////////////////////////*/

    function _setTickBit(Orderbook storage book, int16 tick, bool isBid) internal {
        (int16 word, uint8 bit) = _bitPosition(tick);
        if (isBid) book.bidBitmap[word] |= uint256(1) << bit;
        else book.askBitmap[word] |= uint256(1) << bit;
    }

    function _clearTickBit(Orderbook storage book, int16 tick, bool isBid) internal {
        (int16 word, uint8 bit) = _bitPosition(tick);
        if (isBid) book.bidBitmap[word] &= ~(uint256(1) << bit);
        else book.askBitmap[word] &= ~(uint256(1) << bit);
    }

    function _bitPosition(int16 tick) internal pure returns (int16 word, uint8 bit) {
        if (tick < MIN_TICK || tick > MAX_TICK) revert InvalidTick();
        return (tick >> 8, uint8(uint16(tick)));
    }

    /// Moves the side's best tick past `tick` to the next active tick, or to the empty sentinel.
    function _advanceBestTick(
        Orderbook storage book,
        int16 tick,
        bool isBid
    )
        internal
        returns (int16 nextTick, bool found)
    {
        (nextTick, found) = _nextInitializedTick(book, tick, isBid);
        if (isBid) book.bestBidTick = found ? nextTick : NO_BID;
        else book.bestAskTick = found ? nextTick : NO_ASK;
    }

    /// Next active tick strictly worse than `tick`: lower for bids, higher for asks.
    function _nextInitializedTick(
        Orderbook storage book,
        int16 tick,
        bool isBid
    )
        internal
        view
        returns (int16, bool)
    {
        return isBid ? _nextBidTick(book, tick) : _nextAskTick(book, tick);
    }

    function _nextAskTick(Orderbook storage book, int16 tick) internal view returns (int16, bool) {
        if (tick >= MAX_TICK) return (MAX_TICK, false);
        int16 maxWord = MAX_TICK >> 8;
        int16 t = tick + 1;
        while (true) {
            int16 word = t >> 8;
            // Ignore bits below t.
            uint256 masked = book.askBitmap[word] & (type(uint256).max << uint8(uint16(t)));
            if (masked != 0) {
                int16 found = (word << 8) | int16(uint16(_lsb(masked)));
                return (found, found <= MAX_TICK);
            }
            if (word + 1 > maxWord) return ((word + 1) << 8, false);
            t = (word + 1) << 8;
        }
        revert(); // unreachable
    }

    function _nextBidTick(Orderbook storage book, int16 tick) internal view returns (int16, bool) {
        if (tick <= MIN_TICK) return (MIN_TICK, false);
        int16 minWord = MIN_TICK >> 8;
        int16 t = tick - 1;
        while (true) {
            int16 word = t >> 8;
            // Ignore bits above t.
            uint256 masked = book.bidBitmap[word] & (type(uint256).max >> (255 - uint8(uint16(t))));
            if (masked != 0) {
                int16 found = (word << 8) | int16(uint16(_msb(masked)));
                return (found, found >= MIN_TICK);
            }
            if (word - 1 < minWord) return (((word - 1) << 8) | 0xFF, false);
            t = ((word - 1) << 8) | 0xFF;
        }
        revert(); // unreachable
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function nextOrderId() public view returns (uint128) {
        return _nextOrderId == 0 ? 1 : _nextOrderId;
    }

    function balanceOf(address user, address token) external view returns (uint128) {
        return balances[user][token];
    }

    function getOrder(uint128 orderId) external view returns (Order memory order) {
        order = orders[orderId];
        if (order.maker == address(0) || order.orderId >= nextOrderId()) {
            revert OrderDoesNotExist();
        }
    }

    function books(bytes32 key)
        external
        view
        returns (address base, address quote, int16 bestBidTick, int16 bestAskTick)
    {
        Orderbook storage book = _books[key];
        return (book.base, book.quote, book.bestBidTick, book.bestAskTick);
    }

    /// totalLiquidity is the sum of `remaining` over the tick's queue, computed on read.
    function getTickLevel(
        address base,
        int16 tick,
        bool isBid
    )
        external
        view
        returns (uint128 head, uint128 tail, uint128 totalLiquidity)
    {
        bytes32 key = pairKey(base, _quoteOf(base));
        TickLevel storage level = _level(_books[key], tick, isBid);
        (head, tail) = (level.head, level.tail);
        for (uint128 id = head; id != 0; id = orders[id].next) {
            totalLiquidity += orders[id].remaining;
        }
    }

    function bookIndexForKey(bytes32 bookKey) public view returns (bool exists, uint32 index) {
        Orderbook storage book = _books[bookKey];
        if (book.base == address(0)) revert PairDoesNotExist();
        if (book.bookId == 0) return (false, 0);
        return (true, book.bookId - 1);
    }

    function bookKeyForIndex(uint32 index) public view returns (bytes32) {
        if (index >= bookKeys.length) revert PairDoesNotExist();
        return bookKeys[index];
    }

    /// Permissionless backfill of bookId for pairs created before book IDs existed.
    function setBookIndex(uint32 index) external {
        bytes32 key = bookKeyForIndex(index);
        (bool exists, uint32 current) = bookIndexForKey(key);
        if (exists) {
            if (current == index) return;
            revert IndexAlreadySet();
        }
        _books[key].bookId = index + 1;
    }

    /// Credits come from the protocol's storage gas accounting, which this port doesn't model, so
    /// this always returns zero here.
    function storageCredits(address user) external view returns (uint64) {
        return _storageCredits[user];
    }

    /*//////////////////////////////////////////////////////////////
                         TOKEN / POLICY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _quoteOf(address token) internal view returns (address) {
        return address(ITIP20(token).quoteToken());
    }

    function _hasTIP20Prefix(address token) internal pure returns (bool) {
        return bytes12(bytes20(token)) == TIP20_PREFIX;
    }

    function _requireUSD(address token) internal view {
        if (keccak256(bytes(ITIP20(token).currency())) != keccak256("USD")) {
            revert ITIP20.InvalidCurrency();
        }
    }

    function _ensureNotPaused(address token) internal view {
        if (ITIP20(token).paused()) revert ITIP20.ContractPaused();
    }

    /// Reverts unless `from` may send and `to` may receive `token` under its TIP-403 policy.
    function _ensureTransferAuthorized(address token, address from, address to) internal view {
        uint64 policyId = ITIP20(token).transferPolicyId();
        if (
            !TIP403_REGISTRY.isAuthorizedSender(policyId, from)
                || !TIP403_REGISTRY.isAuthorizedRecipient(policyId, to)
        ) revert ITIP20.PolicyForbids();
    }

    /// Like an authorization check, but a missing or invalid policy counts as unauthorized.
    function _isAuthorizedOrFalse(
        address token,
        address user,
        bool asSender
    )
        internal
        view
        returns (bool)
    {
        uint64 policyId = ITIP20(token).transferPolicyId();
        bytes memory call = asSender
            ? abi.encodeCall(ITIP403Registry.isAuthorizedSender, (policyId, user))
            : abi.encodeCall(ITIP403Registry.isAuthorizedRecipient, (policyId, user));
        (bool success, bytes memory ret) = address(TIP403_REGISTRY).staticcall(call);
        if (success) return abi.decode(ret, (bool));

        bytes4 sel = bytes4(ret);
        if (
            sel == ITIP403Registry.PolicyNotFound.selector
                || sel == ITIP403Registry.InvalidPolicyType.selector
        ) return false;
        assembly {
            revert(add(ret, 32), mload(ret))
        }
    }

    /*//////////////////////////////////////////////////////////////
                              MATH UTILS
    //////////////////////////////////////////////////////////////*/

    function _level(
        Orderbook storage book,
        int16 tick,
        bool isBid
    )
        internal
        view
        returns (TickLevel storage)
    {
        return isBid ? book.bids[tick] : book.asks[tick];
    }

    function _min(uint128 a, uint128 b) internal pure returns (uint128) {
        return a < b ? a : b;
    }

    function _divCeil(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert Overflow();
        return uint128(x);
    }

    function _msb(uint256 x) internal pure returns (uint8 r) {
        for (uint8 s = 128; s > 0; s >>= 1) {
            if (x >= uint256(1) << s) {
                x >>= s;
                r += s;
            }
        }
    }

    function _lsb(uint256 x) internal pure returns (uint8) {
        unchecked {
            return _msb(x & (~x + 1));
        }
    }

}
