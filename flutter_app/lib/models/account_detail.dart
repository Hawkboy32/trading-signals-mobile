import 'position.dart';
import 'trade.dart';

/// Everything the Account Details screen shows for ONE account, assembled by
/// the backend's /account-detail in a single call.
///
/// The three P&L figures are kept separate on purpose - they answer different
/// questions and get conflated constantly:
///   unrealizedPnl - paper gain/loss on positions still OPEN
///   realizedPnl   - actually banked from CLOSED round trips
///   truePnl       - equity minus deposits: has this account made anything
///                   net of the money put into it

/// One fee the broker charged. `amount` is negative (money leaving).
class BrokerFee {
  final String date;
  final String kind;        // REG / TAF / CAT / CONVERSION
  final double amount;
  final String description; // the broker's own wording, kept verbatim

  /// True when this was charged on money coming IN (currency conversion on a
  /// deposit) rather than on trading. Classified server-side by
  /// BrokerFee.is_funding so the app, the dashboard and the backend all split
  /// costs the same way instead of each re-deriving the rule; falls back to the
  /// kind code if talking to an older backend that doesn't send the field.
  final bool isFunding;

  BrokerFee({
    required this.date,
    required this.kind,
    required this.amount,
    required this.description,
    required this.isFunding,
  });

  factory BrokerFee.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String? ?? 'FEE';
    return BrokerFee(
      date: json['date'] as String? ?? '',
      kind: kind,
      amount: (json['amount'] as num?)?.toDouble() ?? 0.0,
      description: json['description'] as String? ?? '',
      isFunding: json['is_funding'] as bool? ?? (kind == 'CONVERSION'),
    );
  }
}

class AccountDetail {
  final String accountId;
  final String nickname;
  final String broker;
  final bool isPaper;

  /// Set when the broker couldn't be reached; balances/positions will be
  /// empty but the closed-trade history (a local DB read) is still valid.
  final String? error;

  final double? equity;
  final double? cash;
  final double? buyingPower;

  final double unrealizedPnl;
  final double realizedPnl;
  // REALIZED P&L today only (closed trades) - not a mark-to-market
  // day's-change figure. See positions_service.py's AccountView docstring
  // for why (most brokers here have no equity-history API to diff against).
  final double realizedPnlToday;
  final double totalDeposited;
  // The original logged total before any real currency-conversion result
  // was recorded against a deposit - see deposits.record_conversion. Equal
  // to totalDeposited until then; kept separately so a trend across future
  // deposits (does the live-equity estimate run high/low vs what actually
  // lands?) stays visible instead of being silently overwritten.
  final double totalDepositedEstimated;
  final double? truePnl;

  final List<OpenPosition> openPositions;
  final List<TradeRecord> closedTrades;

  /// False when this broker exposes no uniform fee endpoint - shown as
  /// "not reported" rather than implying zero fees were charged.
  final bool feesSupported;
  final List<BrokerFee> fees;
  final double totalFees;

  /// The two costs split, because they behave differently and only one of them
  /// shrinks as a proportion as the account grows:
  ///   tradingFees - REG/TAF/CAT, charged per selling day and each rounded UP
  ///                 to a $0.01 minimum, so effectively a fixed daily toll
  ///                 (measured 11-13 Aug: proceeds tripled, fee stayed $0.03/day)
  ///   fundingFees - GBP->USD conversion at ~1.5% of every deposit, proportional
  ///                 to what goes in and never outgrown
  final double tradingFees;
  final double fundingFees;

  /// Realised P&L AFTER broker charges - the figure that actually
  /// reconciles against equity.
  final double realizedPnlNet;

  /// Realised P&L against the cost of TRADING only, ignoring the cost of
  /// funding the account. Answers "is the strategy paying for the act of
  /// trading" separately from "have the deposit charges been earned back".
  final double realizedPnlAfterTradingFees;

  AccountDetail({
    required this.accountId,
    required this.nickname,
    required this.broker,
    required this.isPaper,
    required this.error,
    required this.equity,
    required this.cash,
    required this.buyingPower,
    required this.unrealizedPnl,
    required this.realizedPnl,
    required this.realizedPnlToday,
    required this.totalDeposited,
    required this.totalDepositedEstimated,
    required this.truePnl,
    required this.openPositions,
    required this.closedTrades,
    required this.feesSupported,
    required this.fees,
    required this.totalFees,
    required this.tradingFees,
    required this.fundingFees,
    required this.realizedPnlNet,
    required this.realizedPnlAfterTradingFees,
  });

  factory AccountDetail.fromJson(Map<String, dynamic> json) {
    final totalDeposited = (json['total_deposited'] as num?)?.toDouble() ?? 0.0;
    return AccountDetail(
      accountId: json['account_id'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      broker: json['broker'] as String? ?? '',
      isPaper: json['is_paper'] as bool? ?? true,
      error: json['error'] as String?,
      equity: (json['equity'] as num?)?.toDouble(),
      cash: (json['cash'] as num?)?.toDouble(),
      buyingPower: (json['buying_power'] as num?)?.toDouble(),
      unrealizedPnl: (json['unrealized_pnl'] as num?)?.toDouble() ?? 0.0,
      realizedPnl: (json['realized_pnl'] as num?)?.toDouble() ?? 0.0,
      realizedPnlToday: (json['realized_pnl_today'] as num?)?.toDouble() ?? 0.0,
      totalDeposited: totalDeposited,
      totalDepositedEstimated:
          (json['total_deposited_estimated'] as num?)?.toDouble() ?? totalDeposited,
      truePnl: (json['true_pnl'] as num?)?.toDouble(),
      openPositions: (json['open_positions'] as List<dynamic>? ?? [])
          .map((e) => OpenPosition.fromJson(e as Map<String, dynamic>))
          .toList(),
      closedTrades: (json['closed_trades'] as List<dynamic>? ?? [])
          .map((e) => TradeRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
      feesSupported: json['fees_supported'] as bool? ?? false,
      fees: (json['fees'] as List<dynamic>? ?? [])
          .map((e) => BrokerFee.fromJson(e as Map<String, dynamic>))
          .toList(),
      totalFees: (json['total_fees'] as num?)?.toDouble() ?? 0.0,
      tradingFees: (json['trading_fees'] as num?)?.toDouble() ?? 0.0,
      fundingFees: (json['funding_fees'] as num?)?.toDouble() ?? 0.0,
      realizedPnlNet: (json['realized_pnl_net'] as num?)?.toDouble() ?? 0.0,
      realizedPnlAfterTradingFees:
          (json['realized_pnl_after_trading_fees'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
