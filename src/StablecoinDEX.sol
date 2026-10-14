// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

import {ITIP20} from "tempo-std/interfaces/ITIP20.sol";
import {ITIP20Factory} from "tempo-std/interfaces/ITIP20Factory.sol";
import {ITIP403Registry} from "tempo-std/interfaces/ITIP403Registry.sol";

/// @title StablecoinDEX
///
/// @notice Solidity port of Tempo's StablecoinDEX precompile at 0xDEc0000000000000000000000000000000000000,
///         written for reading, not deployment.
///
/// @dev Matches the Rust precompile at the latest hardfork. Pre-fork code paths are dropped; see README.md for what
///      is not modelled.
/// @dev One central limit order book per (base, quote) pair. Every TIP-20 has exactly one quote token, so pairs form
///      a tree rooted at pathUSD and multi-hop swaps route through the lowest common ancestor. Prices are ticks of
///      0.1 bp around 1.0: `price = PRICE_SCALE + tick`.
contract StablecoinDEX {
    /// @notice A resting limit order.
    struct Order {
        /// @dev Sequential ID, starting at 1.
        uint128 orderId;
        /// @dev Address that placed the order.
        address maker;
        /// @dev `pairKey(base, quote)` of the order's book.
        bytes32 bookKey;
        /// @dev True for a bid (buys base), false for an ask (sells base).
        bool isBid;
        /// @dev Price tick.
        int16 tick;
        /// @dev Original base amount.
        uint128 amount;
        /// @dev Unfilled base amount.
        uint128 remaining;
        /// @dev Previous order in the tick's FIFO queue; 0 at the head.
        uint128 prev;
        /// @dev Next order in the tick's FIFO queue; 0 at the tail.
        uint128 next;
        /// @dev Whether the order re-posts on the opposite side when fully filled.
        bool isFlip;
        /// @dev Tick the order re-posts at when fully filled; 0 for non-flip orders.
        int16 flipTick;
    }

    /// @notice FIFO queue of orders at one tick on one side of a book.
    struct TickLevel {
        /// @dev First order ID; 0 if empty.
        uint128 head;
        /// @dev Last order ID; 0 if empty.
        uint128 tail;
        /// @dev Unused; keeps the precompile's slot layout. `getTickLevel` computes liquidity on read.
        uint128 totalLiquidity;
    }

    /// @notice Order book for one (base, quote) pair.
    struct Orderbook {
        /// @dev Base token.
        address base;
        /// @dev Quote token, `base.quoteToken()`.
        address quote;
        /// @dev Bid queues by tick.
        mapping(int16 tick => TickLevel level) bids;
        /// @dev Ask queues by tick.
        mapping(int16 tick => TickLevel level) asks;
        /// @dev Highest active bid tick, or `NO_BID`.
        int16 bestBidTick;
        /// @dev Lowest active ask tick, or `NO_ASK`.
        int16 bestAskTick;
        /// @dev Index into `_bookKeys` plus one; 0 means unset. The precompile packs this into order records in place
        ///      of the 32-byte book key.
        uint32 bookId;
        /// @dev One bit per active bid tick, 256 ticks per word, keyed by `tick >> 8`.
        mapping(int16 word => uint256 bits) bidBitmap;
        /// @dev One bit per active ask tick, 256 ticks per word, keyed by `tick >> 8`.
        mapping(int16 word => uint256 bits) askBitmap;
    }

    /// @notice Result of trading against one resting order. Shared by swaps and quotes so the two always agree.
    struct Step {
        /// @dev Base filled from this order. Below `order.remaining` means this order ends the trade.
        uint128 fillAmount;
        /// @dev Added to the running total: taker output for exact-in, taker input for exact-out.
        uint128 accumulate;
        /// @dev Input (exact-in) or output (exact-out) still owed after fully consuming this order.
        uint128 nextAmount;
    }

    /// @notice One book on a swap route.
    struct Hop {
        /// @dev Book to trade on.
        bytes32 bookKey;
        /// @dev True when the taker sells base into bids, false when buying base from asks.
        bool baseForQuote;
    }

    /// @notice Lowest tick, price 0.98.
    int16 public constant MIN_TICK = -2000;

    /// @notice Highest tick, price 1.02.
    int16 public constant MAX_TICK = 2000;

    /// @notice Order ticks must be multiples of this.
    int16 public constant TICK_SPACING = 10;

    /// @notice Scaled price at tick 0 (1.0).
    uint32 public constant PRICE_SCALE = 100_000;

    /// @notice Scaled price at `MIN_TICK`.
    uint32 public constant MIN_PRICE = 98_000;

    /// @notice Scaled price at `MAX_TICK`.
    uint32 public constant MAX_PRICE = 102_000;

    /// @notice Smallest order, in base units: 100 tokens at 6 decimals.
    uint128 public constant MIN_ORDER_AMOUNT = 100_000_000;

    address private constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    ITIP20Factory private constant TIP20_FACTORY = ITIP20Factory(0x20Fc000000000000000000000000000000000000);
    ITIP403Registry private constant TIP403_REGISTRY = ITIP403Registry(0x403c000000000000000000000000000000000000);
    bytes12 private constant TIP20_PREFIX = 0x20c000000000000000000000;

    /// @dev Best-tick sentinels for an empty side.
    int16 private constant NO_BID = type(int16).min;
    int16 private constant NO_ASK = type(int16).max;

    // Declared in the precompile's slot order. Order records differ physically: the precompile writes a packed layout.

    mapping(bytes32 bookKey => Orderbook book) private _books;
    mapping(uint128 orderId => Order order) private _orders;
    /// @dev Escrow refunds, fill proceeds, and funds makers leave on the DEX.
    mapping(address user => mapping(address token => uint128 amount)) private _balances;
    uint128 private _nextOrderId;
    bytes32[] private _bookKeys;
    mapping(address user => uint64 credits) private _storageCredits;

    /// @notice Emitted when a pair is created.
    ///
    /// @param key   `pairKey(base, quote)`.
    /// @param base  Base token.
    /// @param quote Quote token.
    event PairCreated(bytes32 indexed key, address indexed base, address indexed quote);

    /// @notice Emitted when an order is placed.
    ///
    /// @param orderId     New order ID.
    /// @param maker       Address that placed the order.
    /// @param token       Base token of the pair.
    /// @param amount      Base amount.
    /// @param isBid       True for a bid, false for an ask.
    /// @param tick        Price tick.
    /// @param isFlipOrder Whether this is a flip order.
    /// @param flipTick    Flip tick; 0 for non-flip orders.
    event OrderPlaced(
        uint128 indexed orderId,
        address indexed maker,
        address indexed token,
        uint128 amount,
        bool isBid,
        int16 tick,
        bool isFlipOrder,
        int16 flipTick
    );

    /// @notice Emitted for each order a swap fills, fully or partially.
    ///
    /// @param orderId      Filled order.
    /// @param maker        Order's maker.
    /// @param taker        Swapper.
    /// @param amountFilled Base amount filled.
    /// @param partialFill  True if the order still has a remainder.
    event OrderFilled(
        uint128 indexed orderId, address indexed maker, address indexed taker, uint128 amountFilled, bool partialFill
    );

    /// @notice Emitted when a fully filled flip order re-posts on the opposite side under the same ID.
    ///
    /// @param orderId  Order ID, unchanged.
    /// @param maker    Order's maker.
    /// @param token    Base token of the pair.
    /// @param amount   Base amount.
    /// @param isBid    New side.
    /// @param tick     New tick, the old flip tick.
    /// @param flipTick New flip tick, the old tick.
    event OrderFlipped(
        uint128 indexed orderId,
        address indexed maker,
        address indexed token,
        uint128 amount,
        bool isBid,
        int16 tick,
        int16 flipTick
    );

    /// @notice Emitted when a fully filled flip order can't re-post. The order is deleted and the swap continues.
    ///
    /// @param orderId Order ID.
    /// @param maker   Order's maker.
    /// @param reason  Selector of the error that stopped the flip.
    event FlipFailed(uint128 indexed orderId, address indexed maker, bytes4 reason);

    /// @notice Emitted when an order is cancelled and its escrow refunded.
    ///
    /// @param orderId Cancelled order.
    event OrderCancelled(uint128 indexed orderId);

    /// @notice Thrown when the caller isn't allowed to act on the order.
    error Unauthorized();

    /// @notice Thrown when no book exists for a pair or route hop.
    error PairDoesNotExist();

    /// @notice Thrown by `createPair` for an existing pair.
    error PairAlreadyExists();

    /// @notice Thrown when the order doesn't exist or is already filled or cancelled.
    error OrderDoesNotExist();

    /// @notice Thrown when a swap's input and output tokens are the same.
    error IdenticalTokens();

    /// @notice Thrown when a swap token lacks the TIP-20 address prefix.
    error InvalidToken();

    /// @notice Thrown when a tick or flip tick is outside `[MIN_TICK, MAX_TICK]`, or a price outside
    ///         `[MIN_PRICE, MAX_PRICE]`.
    ///
    /// @param tick The out-of-range tick.
    error TickOutOfBounds(int16 tick);

    /// @notice Thrown when a tick isn't a multiple of `TICK_SPACING`.
    error InvalidTick();

    /// @notice Thrown when a flip tick is misaligned or on the wrong side of the order's tick.
    error InvalidFlipTick();

    /// @notice Thrown when a DEX balance can't cover a withdrawal or flip escrow.
    error InsufficientBalance();

    /// @notice Thrown when the book runs out of orders before the swap completes.
    error InsufficientLiquidity();

    /// @notice Thrown when `swapExactAmountIn` output is below `minAmountOut`.
    error InsufficientOutput();

    /// @notice Thrown when `swapExactAmountOut` input exceeds `maxAmountIn`.
    error MaxInputExceeded();

    /// @notice Thrown when an order is below `MIN_ORDER_AMOUNT`.
    ///
    /// @param amount The order amount.
    error BelowMinimumOrderSize(uint128 amount);

    /// @notice Thrown by `createPair` when the base isn't a TIP-20 from the factory.
    error InvalidBaseToken();

    /// @notice Thrown by `cancelStaleOrder` when the maker is still authorized.
    error OrderNotStale();

    /// @notice Thrown by `setBookIndex` when the book already has a different index.
    error IndexAlreadySet();

    /// @notice Thrown when an amount doesn't fit in a uint128.
    error Overflow();

    /// @notice Thrown when a flip reverts without an error selector, such as running out of gas.
    error FlipRevertedWithoutReason();

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates the book for `base` and its quote token. Both must be USD TIP-20s.
    ///
    /// @param base Base token.
    ///
    /// @return The new book's key.
    function createPair(address base) external returns (bytes32) {
        return _createPair(base);
    }

    /// @notice Places a limit order, creating the pair if needed. Escrow comes from the caller's DEX balance first,
    ///         then their wallet.
    ///
    /// @param token  Base token.
    /// @param amount Base amount.
    /// @param isBid  True to buy base, false to sell.
    /// @param tick   Price tick.
    ///
    /// @return The new order's ID.
    function place(address token, uint128 amount, bool isBid, int16 tick) external returns (uint128) {
        return
            _place({
                maker: msg.sender, base: token, amount: amount, isBid: isBid, tick: tick, isFlip: false, flipTick: 0
            });
    }

    /// @notice Places a flip order, which re-posts itself on the opposite side at `flipTick` each time it fully
    ///         fills, funded from the fill's proceeds.
    ///
    /// @dev A bid's flip tick must be >= its tick and an ask's <= its tick, so the proceeds cover the new escrow.
    ///
    /// @param token    Base token.
    /// @param amount   Base amount.
    /// @param isBid    True to buy base first, false to sell first.
    /// @param tick     Price tick.
    /// @param flipTick Tick to re-post at after a full fill.
    ///
    /// @return The new order's ID.
    function placeFlip(address token, uint128 amount, bool isBid, int16 tick, int16 flipTick)
        external
        returns (uint128)
    {
        return _place({
            maker: msg.sender, base: token, amount: amount, isBid: isBid, tick: tick, isFlip: true, flipTick: flipTick
        });
    }

    /// @notice Cancels the caller's order and refunds its escrow to their DEX balance.
    ///
    /// @param orderId Order to cancel.
    function cancel(uint128 orderId) external {
        Order memory order = _orders[orderId];
        if (order.maker == address(0)) revert OrderDoesNotExist();
        if (order.maker != msg.sender) revert Unauthorized();
        if (order.remaining == 0) revert OrderDoesNotExist();
        _cancelActive(order);
    }

    /// @notice Cancels any order whose maker the token policies no longer allow to send the escrow token or receive
    ///         the payout token. Callable by anyone.
    ///
    /// @param orderId Order to cancel.
    function cancelStaleOrder(uint128 orderId) external {
        Order memory order = _orders[orderId];
        if (order.maker == address(0)) revert OrderDoesNotExist();
        if (_isMakerAuthorized(order)) revert OrderNotStale();
        _cancelActive(order);
    }

    /// @notice Transfers tokens from the caller's DEX balance to their wallet.
    ///
    /// @param token  Token to withdraw.
    /// @param amount Amount to withdraw.
    function withdraw(address token, uint128 amount) external {
        uint128 balance = _balances[msg.sender][token];
        if (balance < amount) revert InsufficientBalance();
        _balances[msg.sender][token] = balance - amount;
        ITIP20(token).transfer({to: msg.sender, amount: amount});
    }

    /// @notice Sells exactly `amountIn` of `tokenIn` for `tokenOut`, routing through as many books as needed.
    ///
    /// @param tokenIn      Token to sell.
    /// @param tokenOut     Token to buy.
    /// @param amountIn     Amount to sell.
    /// @param minAmountOut Minimum acceptable output.
    ///
    /// @return Amount of `tokenOut` received.
    function swapExactAmountIn(address tokenIn, address tokenOut, uint128 amountIn, uint128 minAmountOut)
        external
        returns (uint128)
    {
        Hop[] memory route = _findTradePath({tokenIn: tokenIn, tokenOut: tokenOut});
        // Route tokens were pause-checked in _findTradePath.
        _debitOrPull({user: msg.sender, token: tokenIn, amount: amountIn, checkPause: false});

        // Intermediate hop amounts never leave the DEX.
        uint128 amount = amountIn;
        for (uint256 i = 0; i < route.length; i++) {
            amount = _fillHop({hop: route[i], amount: amount, exactIn: true, taker: msg.sender});
        }
        if (amount < minAmountOut) revert InsufficientOutput();

        ITIP20(tokenOut).transfer({to: msg.sender, amount: amount});
        return amount;
    }

    /// @notice Buys exactly `amountOut` of `tokenOut` with `tokenIn`, routing through as many books as needed.
    ///
    /// @param tokenIn     Token to sell.
    /// @param tokenOut    Token to buy.
    /// @param amountOut   Amount to buy.
    /// @param maxAmountIn Maximum acceptable input.
    ///
    /// @return Amount of `tokenIn` spent.
    function swapExactAmountOut(address tokenIn, address tokenOut, uint128 amountOut, uint128 maxAmountIn)
        external
        returns (uint128)
    {
        Hop[] memory route = _findTradePath({tokenIn: tokenIn, tokenOut: tokenOut});

        // Walk backwards from the output to find the input each hop needs.
        uint128 amount = amountOut;
        for (uint256 i = route.length; i > 0; i--) {
            amount = _fillHop({hop: route[i - 1], amount: amount, exactIn: false, taker: msg.sender});
        }
        if (amount > maxAmountIn) revert MaxInputExceeded();

        _debitOrPull({user: msg.sender, token: tokenIn, amount: amount, checkPause: false});
        ITIP20(tokenOut).transfer({to: msg.sender, amount: amountOut});
        return amount;
    }

    /// @notice Backfills the book ID for a pair created before book IDs existed. Callable by anyone.
    ///
    /// @param index Index of the book in the book key list.
    function setBookIndex(uint32 index) external {
        bytes32 key = bookKeyForIndex(index);
        (bool exists, uint32 current) = bookIndexForKey(key);
        if (exists) {
            if (current == index) return;
            revert IndexAlreadySet();
        }
        _books[key].bookId = index + 1;
    }

    /// @notice Re-posts a fully filled flip order on the opposite side. Only callable by this contract, so a failing
    ///         flip reverts only its own changes, as the precompile's storage checkpoint does.
    ///
    /// @dev Escrow comes only from the maker's DEX balance, never their wallet.
    ///
    /// @param order The filled order, as it was before the fill.
    function selfFlipInPlace(Order memory order) external {
        if (msg.sender != address(this)) revert Unauthorized();

        Orderbook storage book = _books[order.bookKey];
        Order memory flipped = Order({
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

        (address escrowToken, uint128 escrowAmount, address payoutToken) = _escrowFor({
            base: book.base, quote: book.quote, amount: flipped.amount, isBid: flipped.isBid, tick: flipped.tick
        });

        uint128 balance = _balances[flipped.maker][escrowToken];
        if (balance < escrowAmount) revert InsufficientBalance();
        _ensureNotPaused(escrowToken);
        _ensureTransferAuthorized({token: escrowToken, from: flipped.maker, to: address(this)});
        _ensureNotPaused(payoutToken);
        _ensureTransferAuthorized({token: payoutToken, from: address(this), to: flipped.maker});
        _balances[flipped.maker][escrowToken] = balance - escrowAmount;

        _commitOrderToBook(flipped);

        emit OrderFlipped({
            orderId: flipped.orderId,
            maker: flipped.maker,
            token: book.base,
            amount: flipped.amount,
            isBid: flipped.isBid,
            tick: flipped.tick,
            flipTick: flipped.flipTick
        });
    }

    /// @notice Quotes `swapExactAmountIn`. Walks the same orders with the same arithmetic, so the quote is exact.
    ///
    /// @param tokenIn  Token to sell.
    /// @param tokenOut Token to buy.
    /// @param amountIn Amount to sell.
    ///
    /// @return Amount of `tokenOut` a swap would return.
    function quoteSwapExactAmountIn(address tokenIn, address tokenOut, uint128 amountIn)
        external
        view
        returns (uint128)
    {
        Hop[] memory route = _findTradePath({tokenIn: tokenIn, tokenOut: tokenOut});
        uint128 amount = amountIn;
        for (uint256 i = 0; i < route.length; i++) {
            amount = _quoteHop({hop: route[i], amount: amount, exactIn: true});
        }
        return amount;
    }

    /// @notice Quotes `swapExactAmountOut`. Walks the same orders with the same arithmetic, so the quote is exact.
    ///
    /// @param tokenIn   Token to sell.
    /// @param tokenOut  Token to buy.
    /// @param amountOut Amount to buy.
    ///
    /// @return Amount of `tokenIn` a swap would spend.
    function quoteSwapExactAmountOut(address tokenIn, address tokenOut, uint128 amountOut)
        external
        view
        returns (uint128)
    {
        Hop[] memory route = _findTradePath({tokenIn: tokenIn, tokenOut: tokenOut});
        uint128 amount = amountOut;
        for (uint256 i = route.length; i > 0; i--) {
            amount = _quoteHop({hop: route[i - 1], amount: amount, exactIn: false});
        }
        return amount;
    }

    /// @notice Returns a user's DEX balance.
    ///
    /// @param user  Account.
    /// @param token Token.
    ///
    /// @return The balance.
    function balanceOf(address user, address token) external view returns (uint128) {
        return _balances[user][token];
    }

    /// @notice Returns an active order.
    ///
    /// @param orderId Order ID.
    ///
    /// @return The order.
    function getOrder(uint128 orderId) external view returns (Order memory) {
        Order memory order = _orders[orderId];
        if (order.maker == address(0) || order.orderId >= nextOrderId()) revert OrderDoesNotExist();
        return order;
    }

    /// @notice Returns a book's tokens and best ticks. Zeroes for a missing book.
    ///
    /// @param key Book key.
    ///
    /// @return base        Base token.
    /// @return quote       Quote token.
    /// @return bestBidTick Highest active bid tick, or `type(int16).min` if none.
    /// @return bestAskTick Lowest active ask tick, or `type(int16).max` if none.
    function books(bytes32 key)
        external
        view
        returns (address base, address quote, int16 bestBidTick, int16 bestAskTick)
    {
        Orderbook storage book = _books[key];
        return (book.base, book.quote, book.bestBidTick, book.bestAskTick);
    }

    /// @notice Returns one tick's order queue.
    ///
    /// @param base  Base token of the pair.
    /// @param tick  Price tick.
    /// @param isBid True for the bid side.
    ///
    /// @return head           First order ID; 0 if empty.
    /// @return tail           Last order ID; 0 if empty.
    /// @return totalLiquidity Sum of `remaining` over the queue.
    function getTickLevel(address base, int16 tick, bool isBid)
        external
        view
        returns (uint128 head, uint128 tail, uint128 totalLiquidity)
    {
        bytes32 key = pairKey({tokenA: base, tokenB: _quoteOf(base)});
        TickLevel storage level = _level({book: _books[key], tick: tick, isBid: isBid});
        head = level.head;
        tail = level.tail;
        for (uint128 id = head; id != 0; id = _orders[id].next) {
            totalLiquidity += _orders[id].remaining;
        }
        return (head, tail, totalLiquidity);
    }

    /// @notice Returns a user's storage credits. Always 0 here: credits come from the protocol's storage gas
    ///         accounting, which this port doesn't model.
    ///
    /// @param user Account.
    ///
    /// @return The credit count.
    function storageCredits(address user) external view returns (uint64) {
        return _storageCredits[user];
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the ID the next order will get.
    ///
    /// @return The next order ID, at least 1.
    function nextOrderId() public view returns (uint128) {
        return _nextOrderId == 0 ? 1 : _nextOrderId;
    }

    /// @notice Returns a book's position in the book key list.
    ///
    /// @param bookKey Book key.
    ///
    /// @return exists Whether the book has an ID.
    /// @return index  Position in the list; 0 if unset.
    function bookIndexForKey(bytes32 bookKey) public view returns (bool exists, uint32 index) {
        Orderbook storage book = _books[bookKey];
        if (book.base == address(0)) revert PairDoesNotExist();
        if (book.bookId == 0) return (false, 0);
        return (true, book.bookId - 1);
    }

    /// @notice Returns the book key at a position in the book key list.
    ///
    /// @param index Position in the list.
    ///
    /// @return The book key.
    function bookKeyForIndex(uint32 index) public view returns (bytes32) {
        if (index >= _bookKeys.length) revert PairDoesNotExist();
        return _bookKeys[index];
    }

    /// @notice Returns `keccak256(abi.encodePacked(tokenA, tokenB))`. Argument order matters: base first.
    ///
    /// @param tokenA Base token.
    /// @param tokenB Quote token.
    ///
    /// @return The book key.
    function pairKey(address tokenA, address tokenB) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenA, tokenB));
    }

    /// @notice Converts a tick to a scaled price.
    ///
    /// @param tick Price tick, a multiple of `TICK_SPACING`.
    ///
    /// @return `PRICE_SCALE + tick`.
    function tickToPrice(int16 tick) public pure returns (uint32) {
        if (tick % TICK_SPACING != 0) revert InvalidTick();
        return _price(tick);
    }

    /// @notice Converts a scaled price to a tick.
    ///
    /// @param price Scaled price in `[MIN_PRICE, MAX_PRICE]`.
    ///
    /// @return `price - PRICE_SCALE`.
    function priceToTick(uint32 price) public pure returns (int16) {
        int16 tick;
        unchecked {
            tick = int16(int32(price) - int32(PRICE_SCALE));
        }
        if (price < MIN_PRICE || price > MAX_PRICE) revert TickOutOfBounds(tick);
        if (tick % TICK_SPACING != 0) revert InvalidTick();
        return tick;
    }

    /*//////////////////////////////////////////////////////////////
                           PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createPair(address base) private returns (bytes32) {
        if (!TIP20_FACTORY.isTIP20(base)) revert InvalidBaseToken();
        address quote = _quoteOf(base);
        _requireUSD(base);
        _requireUSD(quote);

        bytes32 key = pairKey({tokenA: base, tokenB: quote});
        Orderbook storage book = _books[key];
        if (book.base != address(0)) revert PairAlreadyExists();

        book.base = base;
        book.quote = quote;
        book.bestBidTick = NO_BID;
        book.bestAskTick = NO_ASK;
        book.bookId = uint32(_bookKeys.length) + 1;
        _bookKeys.push(key);

        emit PairCreated({key: key, base: base, quote: quote});
        return key;
    }

    function _place(address maker, address base, uint128 amount, bool isBid, int16 tick, bool isFlip, int16 flipTick)
        private
        returns (uint128)
    {
        address quote = _quoteOf(base);
        bytes32 key = pairKey({tokenA: base, tokenB: quote});
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
            _escrowFor({base: base, quote: quote, amount: amount, isBid: isBid, tick: tick});

        // The maker must be able to receive the payout token. Fills credit it internally, which bypasses TIP-20's
        // pause check, so pause is checked here instead.
        _ensureTransferAuthorized({token: payoutToken, from: address(this), to: maker});
        _ensureNotPaused(payoutToken);

        _debitOrPull({user: maker, token: escrowToken, amount: escrowAmount, checkPause: true});

        uint128 orderId = nextOrderId();
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

        emit OrderPlaced({
            orderId: orderId,
            maker: maker,
            token: base,
            amount: amount,
            isBid: isBid,
            tick: tick,
            isFlipOrder: isFlip,
            flipTick: flipTick
        });
        return orderId;
    }

    /// @dev Appends the order to the FIFO queue at its tick.
    function _commitOrderToBook(Order memory order) private {
        Orderbook storage book = _books[order.bookKey];
        TickLevel storage level = _level({book: book, tick: order.tick, isBid: order.isBid});

        uint128 prevTail = level.tail;
        if (prevTail == 0) {
            level.head = order.orderId;
            level.tail = order.orderId;
            _setTickBit({book: book, tick: order.tick, isBid: order.isBid});
            if (order.isBid) {
                if (order.tick > book.bestBidTick) book.bestBidTick = order.tick;
            } else if (order.tick < book.bestAskTick) {
                book.bestAskTick = order.tick;
            }
        } else {
            _orders[prevTail].next = order.orderId;
            order.prev = prevTail;
            level.tail = order.orderId;
        }

        _orders[order.orderId] = order;
    }

    /// @dev Unlinks the order, refunds its remaining escrow to the maker's DEX balance, and deletes it.
    function _cancelActive(Order memory order) private {
        Orderbook storage book = _books[order.bookKey];
        TickLevel storage level = _level({book: book, tick: order.tick, isBid: order.isBid});

        if (order.prev != 0) _orders[order.prev].next = order.next;
        else level.head = order.next;
        if (order.next != 0) _orders[order.next].prev = order.prev;
        else level.tail = order.prev;

        if (level.head == 0) {
            _clearTickBit({book: book, tick: order.tick, isBid: order.isBid});
            int16 best = order.isBid ? book.bestBidTick : book.bestAskTick;
            if (best == order.tick) _advanceBestTick({book: book, tick: order.tick, isBid: order.isBid});
        }

        if (order.isBid) {
            _balances[order.maker][book.quote] += _baseToQuote({base: order.remaining, tick: order.tick, roundUp: true});
        } else {
            _balances[order.maker][book.base] += order.remaining;
        }

        delete _orders[order.orderId];
        emit OrderCancelled(order.orderId);
    }

    /// @dev Fills resting orders on one book, best price first and FIFO within a tick, until `amount` is used up.
    ///      Returns output for exact-in, input for exact-out.
    function _fillHop(Hop memory hop, uint128 amount, bool exactIn, address taker) private returns (uint128) {
        bool isBid = hop.baseForQuote;
        Order memory order = _bestOrder({key: hop.bookKey, isBid: isBid});
        uint128 total;

        while (amount > 0) {
            Step memory step = exactIn
                ? _stepExactIn({amountIn: amount, order: order, isBid: isBid})
                : _stepExactOut({amountOut: amount, order: order, isBid: isBid});

            if (step.fillAmount < order.remaining) {
                _partialFill({order: order, fill: step.fillAmount, taker: taker});
                total += step.accumulate;
                break;
            }

            (bool hasNext, Order memory next) = _fillOrder({key: hop.bookKey, order: order, taker: taker});
            total += step.accumulate;
            if (!hasNext) {
                if (step.nextAmount > 0) revert InsufficientLiquidity();
                break;
            }
            order = next;
            amount = step.nextAmount;
        }
        return total;
    }

    /// @dev Fully fills `order`, flips or deletes it, and returns the next order on the same side. Maker transfer
    ///      policy is not checked, so a blocked maker can't halt swaps on the pair; `cancelStaleOrder` removes such
    ///      orders.
    function _fillOrder(bytes32 key, Order memory order, address taker)
        private
        returns (bool hasNext, Order memory next)
    {
        Orderbook storage book = _books[key];

        _creditMaker({order: order, fill: order.remaining});
        emit OrderFilled({
            orderId: order.orderId, maker: order.maker, taker: taker, amountFilled: order.remaining, partialFill: false
        });

        // A flip rewrites the record under the same ID. A failed flip doesn't block the swap.
        bool flipped;
        if (order.isFlip) {
            try this.selfFlipInPlace(order) {
                flipped = true;
            } catch (bytes memory reason) {
                if (reason.length < 4) revert FlipRevertedWithoutReason();
                emit FlipFailed({orderId: order.orderId, maker: order.maker, reason: bytes4(reason)});
            }
        }
        if (!flipped) delete _orders[order.orderId];

        TickLevel storage level = _level({book: book, tick: order.tick, isBid: order.isBid});
        if (order.next != 0) {
            level.head = order.next;
            _orders[order.next].prev = 0;
            return (true, _orders[order.next]);
        }

        // Tick exhausted.
        delete level.head;
        delete level.tail;
        _clearTickBit({book: book, tick: order.tick, isBid: order.isBid});
        (int16 nextTick, bool found) = _advanceBestTick({book: book, tick: order.tick, isBid: order.isBid});
        if (!found) return (false, next);
        return (true, _orders[_level({book: book, tick: nextTick, isBid: order.isBid}).head]);
    }

    function _partialFill(Order memory order, uint128 fill, address taker) private {
        _orders[order.orderId].remaining = order.remaining - fill;
        _creditMaker({order: order, fill: fill});
        emit OrderFilled({
            orderId: order.orderId, maker: order.maker, taker: taker, amountFilled: fill, partialFill: true
        });
    }

    /// @dev Bid makers receive base exactly; ask makers receive quote rounded up.
    function _creditMaker(Order memory order, uint128 fill) private {
        Orderbook storage book = _books[order.bookKey];
        if (order.isBid) {
            _balances[order.maker][book.base] += fill;
        } else {
            _balances[order.maker][book.quote] += _baseToQuote({base: fill, tick: order.tick, roundUp: true});
        }
    }

    /// @dev Debits the user's DEX balance, pulling any shortfall from their wallet.
    function _debitOrPull(address user, address token, uint128 amount, bool checkPause) private {
        _ensureTransferAuthorized({token: token, from: user, to: address(this)});
        uint128 balance = _balances[user][token];
        if (balance >= amount) {
            // No TIP-20 transfer runs, so nothing else checks pause.
            if (checkPause) _ensureNotPaused(token);
            _balances[user][token] = balance - amount;
        } else {
            // The precompile calls TIP-20 systemTransferFrom, which needs no allowance for the DEX.
            ITIP20(token).transferFrom({from: user, to: address(this), amount: amount - balance});
            _balances[user][token] = 0;
        }
    }

    function _setTickBit(Orderbook storage book, int16 tick, bool isBid) private {
        (int16 word, uint8 bit) = _bitPosition(tick);
        if (isBid) book.bidBitmap[word] |= uint256(1) << bit;
        else book.askBitmap[word] |= uint256(1) << bit;
    }

    function _clearTickBit(Orderbook storage book, int16 tick, bool isBid) private {
        (int16 word, uint8 bit) = _bitPosition(tick);
        if (isBid) book.bidBitmap[word] &= ~(uint256(1) << bit);
        else book.askBitmap[word] &= ~(uint256(1) << bit);
    }

    /// @dev Moves the side's best tick past `tick` to the next active tick, or to the empty sentinel.
    function _advanceBestTick(Orderbook storage book, int16 tick, bool isBid)
        private
        returns (int16 nextTick, bool found)
    {
        (nextTick, found) = _nextInitializedTick({book: book, tick: tick, isBid: isBid});
        if (isBid) book.bestBidTick = found ? nextTick : NO_BID;
        else book.bestAskTick = found ? nextTick : NO_ASK;
        return (nextTick, found);
    }

    function _isMakerAuthorized(Order memory order) private view returns (bool) {
        Orderbook storage book = _books[order.bookKey];
        (address escrowToken, address payoutToken) = order.isBid ? (book.quote, book.base) : (book.base, book.quote);
        return _isAuthorizedOrFalse({token: escrowToken, user: order.maker, asSender: true})
            && _isAuthorizedOrFalse({token: payoutToken, user: order.maker, asSender: false});
    }

    /// @dev Read-only twin of `_fillHop`: same steps, same traversal, no settlement.
    function _quoteHop(Hop memory hop, uint128 amount, bool exactIn) private view returns (uint128) {
        bool isBid = hop.baseForQuote;
        Order memory order = _bestOrder({key: hop.bookKey, isBid: isBid});
        uint128 total;

        while (amount > 0) {
            Step memory step = exactIn
                ? _stepExactIn({amountIn: amount, order: order, isBid: isBid})
                : _stepExactOut({amountOut: amount, order: order, isBid: isBid});
            total += step.accumulate;
            if (step.fillAmount < order.remaining) break;

            (bool hasNext, Order memory next) = _orderAfter({key: hop.bookKey, order: order, isBid: isBid});
            if (!hasNext) {
                if (step.nextAmount > 0) revert InsufficientLiquidity();
                break;
            }
            order = next;
            amount = step.nextAmount;
        }
        return total;
    }

    function _bestOrder(bytes32 key, bool isBid) private view returns (Order memory) {
        Orderbook storage book = _books[key];
        int16 tick = isBid ? book.bestBidTick : book.bestAskTick;
        if (tick == (isBid ? NO_BID : NO_ASK)) revert InsufficientLiquidity();
        return _orders[_level({book: book, tick: tick, isBid: isBid}).head];
    }

    /// @dev The order a swap would reach after fully consuming `order`, without changing state.
    function _orderAfter(bytes32 key, Order memory order, bool isBid)
        private
        view
        returns (bool hasNext, Order memory next)
    {
        if (order.next != 0) return (true, _orders[order.next]);
        Orderbook storage book = _books[key];
        (int16 tick, bool found) = _nextInitializedTick({book: book, tick: order.tick, isBid: isBid});
        if (!found) return (false, next);
        return (true, _orders[_level({book: book, tick: tick, isBid: isBid}).head]);
    }

    /// @dev Path is tokenIn -> ... -> LCA -> ... -> tokenOut through the quote-token tree.
    function _findTradePath(address tokenIn, address tokenOut) private view returns (Hop[] memory) {
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

    /// @dev Resolves each adjacent token pair to a book and direction, and rejects paused tokens. TIP-403 policy
    ///      applies only to the taker's input and output, not intermediate tokens.
    function _buildRoute(address[] memory path) private view returns (Hop[] memory) {
        Hop[] memory route = new Hop[](path.length - 1);
        for (uint256 i = 0; i + 1 < path.length; i++) {
            (address hopIn, address hopOut) = (path[i], path[i + 1]);
            _ensureNotPaused(hopIn);

            address base;
            address quote;
            if (_quoteOf(hopIn) == hopOut) (base, quote) = (hopIn, hopOut);
            else if (_quoteOf(hopOut) == hopIn) (base, quote) = (hopOut, hopIn);
            else revert PairDoesNotExist();

            bytes32 key = pairKey({tokenA: base, tokenB: quote});
            if (_books[key].base == address(0)) revert PairDoesNotExist();
            route[i] = Hop({bookKey: key, baseForQuote: hopIn == base});
        }
        return route;
    }

    /// @dev Returns [token, token.quoteToken(), ..., pathUSD].
    function _pathToRoot(address token) private view returns (address[] memory) {
        uint256 length = 1;
        for (address t = token; t != PATH_USD; t = _quoteOf(t)) {
            length++;
        }
        address[] memory path = new address[](length);
        path[0] = token;
        for (uint256 i = 1; i < length; i++) {
            path[i] = _quoteOf(path[i - 1]);
        }
        return path;
    }

    /// @dev Next active tick strictly worse than `tick`: lower for bids, higher for asks.
    function _nextInitializedTick(Orderbook storage book, int16 tick, bool isBid) private view returns (int16, bool) {
        return isBid ? _nextBidTick(book, tick) : _nextAskTick(book, tick);
    }

    function _nextAskTick(Orderbook storage book, int16 tick) private view returns (int16, bool) {
        if (tick >= MAX_TICK) return (MAX_TICK, false);
        int16 start = tick + 1;
        for (int16 word = start >> 8; word <= MAX_TICK >> 8; word++) {
            // In the first word, ignore bits below `start`.
            uint8 fromBit = word == start >> 8 ? uint8(uint16(start)) : 0;
            uint256 masked = book.askBitmap[word] & (type(uint256).max << fromBit);
            if (masked != 0) {
                int16 found = (word << 8) | int16(uint16(_lsb(masked)));
                return (found, found <= MAX_TICK);
            }
        }
        return (((MAX_TICK >> 8) + 1) << 8, false);
    }

    function _nextBidTick(Orderbook storage book, int16 tick) private view returns (int16, bool) {
        if (tick <= MIN_TICK) return (MIN_TICK, false);
        int16 start = tick - 1;
        for (int16 word = start >> 8; word >= MIN_TICK >> 8; word--) {
            // In the first word, ignore bits above `start`.
            uint8 toBit = word == start >> 8 ? uint8(uint16(start)) : 255;
            uint256 masked = book.bidBitmap[word] & (type(uint256).max >> (255 - toBit));
            if (masked != 0) {
                int16 found = (word << 8) | int16(uint16(_msb(masked)));
                return (found, found >= MIN_TICK);
            }
        }
        return ((((MIN_TICK >> 8) - 1) << 8) | 0xFF, false);
    }

    function _quoteOf(address token) private view returns (address) {
        return address(ITIP20(token).quoteToken());
    }

    function _requireUSD(address token) private view {
        if (keccak256(bytes(ITIP20(token).currency())) != keccak256("USD")) revert ITIP20.InvalidCurrency();
    }

    function _ensureNotPaused(address token) private view {
        if (ITIP20(token).paused()) revert ITIP20.ContractPaused();
    }

    /// @dev Reverts unless `from` may send and `to` may receive `token` under its TIP-403 policy.
    function _ensureTransferAuthorized(address token, address from, address to) private view {
        uint64 policyId = ITIP20(token).transferPolicyId();
        if (
            !TIP403_REGISTRY.isAuthorizedSender({policyId: policyId, user: from})
                || !TIP403_REGISTRY.isAuthorizedRecipient({policyId: policyId, user: to})
        ) revert ITIP20.PolicyForbids();
    }

    /// @dev Like an authorization check, but a missing or invalid policy counts as unauthorized.
    function _isAuthorizedOrFalse(address token, address user, bool asSender) private view returns (bool) {
        uint64 policyId = ITIP20(token).transferPolicyId();
        if (asSender) {
            try TIP403_REGISTRY.isAuthorizedSender({policyId: policyId, user: user}) returns (bool authorized) {
                return authorized;
            } catch (bytes memory reason) {
                if (_isPolicyLookupError(reason)) return false;
                // Repeats the call to rethrow its revert.
                return TIP403_REGISTRY.isAuthorizedSender({policyId: policyId, user: user});
            }
        }
        try TIP403_REGISTRY.isAuthorizedRecipient({policyId: policyId, user: user}) returns (bool authorized) {
            return authorized;
        } catch (bytes memory reason) {
            if (_isPolicyLookupError(reason)) return false;
            return TIP403_REGISTRY.isAuthorizedRecipient({policyId: policyId, user: user});
        }
    }

    function _level(Orderbook storage book, int16 tick, bool isBid) private view returns (TickLevel storage) {
        return isBid ? book.bids[tick] : book.asks[tick];
    }

    function _price(int16 tick) private pure returns (uint32) {
        return uint32(int32(PRICE_SCALE) + int32(tick));
    }

    /// @dev base * price / PRICE_SCALE
    function _baseToQuote(uint128 base, int16 tick, bool roundUp) private pure returns (uint128) {
        uint256 n = uint256(base) * _price(tick);
        return _u128(roundUp ? _divCeil(n, PRICE_SCALE) : n / PRICE_SCALE);
    }

    /// @dev quote * PRICE_SCALE / price
    function _quoteToBase(uint128 quote, int16 tick, bool roundUp) private pure returns (uint128) {
        uint256 n = uint256(quote) * PRICE_SCALE;
        uint256 p = _price(tick);
        return _u128(roundUp ? _divCeil(n, p) : n / p);
    }

    /// @dev What the taker receives for `fill` base of an order: quote rounded down when selling into a bid, the base
    ///      itself when buying from an ask.
    function _takerOutput(uint128 fill, int16 tick, bool orderIsBid) private pure returns (uint128) {
        return orderIsBid ? _baseToQuote({base: fill, tick: tick, roundUp: false}) : fill;
    }

    /// @dev Bids escrow quote (rounded up), asks escrow base.
    function _escrowFor(address base, address quote, uint128 amount, bool isBid, int16 tick)
        private
        pure
        returns (address escrowToken, uint128 escrowAmount, address payoutToken)
    {
        if (!isBid) return (base, amount, quote);
        uint256 quoteAmount = _divCeil(uint256(amount) * _price(tick), PRICE_SCALE);
        if (quoteAmount > type(uint128).max) revert InsufficientBalance();
        return (quote, uint128(quoteAmount), base);
    }

    // In the step functions, `isBid` is the route's side and `order.isBid` drives payouts. They match on any valid
    // book.

    function _stepExactIn(uint128 amountIn, Order memory order, bool isBid) private pure returns (Step memory) {
        Step memory step;
        uint128 remaining = order.remaining;
        if (isBid) {
            // Taker sells base.
            step.fillAmount = _min(amountIn, remaining);
            step.nextAmount = amountIn > remaining ? amountIn - remaining : 0;
        } else {
            // Taker pays quote for base; base out rounds down, quote consumed rounds up.
            uint128 baseOut = _quoteToBase({quote: amountIn, tick: order.tick, roundUp: false});
            step.fillAmount = _min(baseOut, remaining);
            if (baseOut > remaining) {
                step.nextAmount = amountIn - _baseToQuote({base: remaining, tick: order.tick, roundUp: true});
            }
        }
        step.accumulate = _takerOutput({fill: step.fillAmount, tick: order.tick, orderIsBid: order.isBid});
        return step;
    }

    function _stepExactOut(uint128 amountOut, Order memory order, bool isBid) private pure returns (Step memory) {
        Step memory step;
        uint128 remaining = order.remaining;
        uint128 demand;
        if (isBid) {
            // Taker wants quote; base needed rounds up.
            demand = _quoteToBase({quote: amountOut, tick: order.tick, roundUp: true});
            step.fillAmount = _min(demand, remaining);
            step.accumulate = step.fillAmount;
        } else {
            // Taker wants base; quote paid rounds up.
            demand = amountOut;
            step.fillAmount = _min(amountOut, remaining);
            step.accumulate = _baseToQuote({base: step.fillAmount, tick: order.tick, roundUp: true});
        }
        if (demand > remaining) {
            step.nextAmount = amountOut - _takerOutput({fill: remaining, tick: order.tick, orderIsBid: order.isBid});
        }
        return step;
    }

    function _bitPosition(int16 tick) private pure returns (int16 word, uint8 bit) {
        if (tick < MIN_TICK || tick > MAX_TICK) revert InvalidTick();
        return (tick >> 8, uint8(uint16(tick)));
    }

    function _isPolicyLookupError(bytes memory reason) private pure returns (bool) {
        bytes4 selector = bytes4(reason);
        return
            selector == ITIP403Registry.PolicyNotFound.selector
                || selector == ITIP403Registry.InvalidPolicyType.selector;
    }

    function _hasTIP20Prefix(address token) private pure returns (bool) {
        return bytes12(bytes20(token)) == TIP20_PREFIX;
    }

    function _min(uint128 a, uint128 b) private pure returns (uint128) {
        return a < b ? a : b;
    }

    function _divCeil(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _u128(uint256 x) private pure returns (uint128) {
        if (x > type(uint128).max) revert Overflow();
        return uint128(x);
    }

    function _msb(uint256 x) private pure returns (uint8) {
        uint8 r;
        for (uint8 s = 128; s > 0; s >>= 1) {
            if (x >= uint256(1) << s) {
                x >>= s;
                r += s;
            }
        }
        return r;
    }

    function _lsb(uint256 x) private pure returns (uint8) {
        unchecked {
            return _msb(x & (~x + 1));
        }
    }
}
