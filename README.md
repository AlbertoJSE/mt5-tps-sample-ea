# TPS Sample Expert Advisor (MetaTrader 5)

A clean, production-style MQL5 implementation of Larry Connors' **TPS — Time, Price, Scale-in**,
a public long-only mean-reversion strategy for equity indices on the daily timeframe.

The strategy itself is public. The purpose of this repository is to show **how I build an
Expert Advisor that does exactly what the research says**, and keeps doing it in live trading.

## Strategy rules

| Step | Rule |
|---|---|
| Trend filter | Close above the 200-day simple moving average |
| Entry | RSI(2) below 25 on two consecutive days → buy 10 % of the full position |
| Scale-in | Each day the close is below the last entry price, add 20 %, 30 %, 40 % (max. 4 tranches) |
| Exit | RSI(2) above 70 → close everything |

## Engineering choices

- **Backtest parity.** The RSI is computed in code with Wilder's smoothing, exactly as in the
  Python research version, so live entries and exits match the backtest trade by trade.
- **Session-aware decision time.** The EA decides a few minutes before the session close and
  uses the live price as the day's close. On short sessions (holidays) it moves the decision earlier.
- **Notional sizing.** Position size is a percentage of equity in notional terms, rounded to the
  broker's volume step and limits.
- **Restart safety.** State (open tranches, last entry price) is stored in terminal global variables
  and rebuilt from the open positions if it is missing.
- **Risk guard.** New entries pause if equity falls more than a set percentage from its peak.
- **Audit trail.** Every daily decision and every fill is written to a CSV file, so live
  execution can be reconciled against the backtest.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `InpSMA` | 200 | Trend filter period |
| `InpRSIIn` / `InpRSIOut` | 25 / 70 | Entry and exit RSI(2) thresholds |
| `InpTranches` | 10,20,30,40 | Scale-in schedule (% of full position) |
| `InpNotionalPct` | 25 | Full position notional, % of equity |
| `InpMaxDDPct` | 8 | Equity drawdown that pauses new entries |
| `InpDecision` | 23:45 | Decision time (server time) |
| `InpMagic` | 900100 | Magic number |

## Usage

1. Copy `TPS_Sample_EA.mq5` into your terminal's `MQL5/Experts` folder and compile it in MetaEditor.
2. Attach it to a chart of an equity index CFD (any timeframe; it reads daily bars).
3. Adjust `InpDecision` to your broker's server time and session close.

## About

I am a self-taught systematic trader and developer (Python, MQL5, Pine Script). I design, validate
and run automated strategies on US indices, gold, FX and US equities, with a research process based
on pre-registered rules, out-of-sample validation, random-entry controls and Monte Carlo risk analysis.

*Educational sample. Not investment advice.*
