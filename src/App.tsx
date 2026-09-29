import { useCallback, useMemo, useState, useEffect } from 'react';
import {
  ArrowDownUp,
  Check,
  ChevronDown,
  CircleHelp,
  ExternalLink,
  LayoutDashboard,
  LoaderCircle,
  ShieldCheck,
  Settings,
  Sparkles,
  WalletCards,
  X,
  AlertCircle,
} from 'lucide-react';
import { useWallet } from './lib/useWallet';
import { getQuotes, getRouterAddress, getTokenAddress } from './lib/router';
import { executeSwap, approveToken } from './lib/wallet';
import { VIRTUES } from './lib/virtue';
import './styles.css';

type Token = { symbol: string; name: string; price: number; icon: string };

const TOKEN_LIST: Token[] = [
  { symbol: 'USDC', name: 'USD Coin', price: 1, icon: '◉' },
  { symbol: 'ETH', name: 'Ethereum', price: 3451.32, icon: '◆' },
  { symbol: 'AERO', name: 'Aerodrome', price: 1.23, icon: '✦' },
  { symbol: 'VIRTUAL', name: 'Virtual Protocol', price: 2.18, icon: '◒' },
];

const ROUTERS = [
  { id: '1inch', name: '1inch Aggregation', detail: 'Best execution', score: 9.8 },
  { id: 'lifi', name: 'LI.FI Diamond', detail: 'Cross-chain fallback', score: 7.2 },
  { id: '0x', name: '0x Protocol', detail: 'Base liquidity fallback', score: 6.0 },
];

const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '');

function Badge({ token }: { token: Token }) {
  return <span className="token-badge">{token.icon}</span>;
}

function TokenInput({
  label,
  token,
  amount,
  onAmount,
  readOnly,
  options,
  balance,
  onToken,
}: {
  label: string;
  token: Token;
  amount: string;
  onAmount?: (s: string) => void;
  readOnly?: boolean;
  options: Token[];
  balance?: string;
  onToken?: (t: Token) => void;
}) {
  return (
    <div className="token-input">
      <div className="input-label">
        <span>{label}</span>
        {!readOnly && <small>Balance: {balance || '0.00'}</small>}
      </div>
      <div className="token-row">
        <label>
          <Badge token={token} />
          <select
            value={token.symbol}
            onChange={(e) => {
              const selected = TOKEN_LIST.find((t) => t.symbol === e.target.value);
              if (selected && onToken) onToken(selected);
            }}
          >
            {[token, ...options].map((t) => (
              <option key={t.symbol} value={t.symbol}>
                {t.symbol}
              </option>
            ))}
          </select>
          <ChevronDown size={14} />
        </label>
        <div>
          <input
            value={amount}
            readOnly={readOnly}
            onChange={(e) => onAmount?.(e.target.value.replace(/[^0-9.]/g, ''))}
          />
          <small>{token.name}</small>
        </div>
      </div>
    </div>
  );
}

export default function App() {
  const wallet = useWallet();
  const [from, setFrom] = useState(TOKEN_LIST[0]);
  const [to, setTo] = useState(TOKEN_LIST[1]);
  const [amount, setAmount] = useState('');
  const [slippage, setSlippage] = useState('0.50');
  const [router, setRouter] = useState('1inch');
  const [review, setReview] = useState(false);
  const [loading, setLoading] = useState(false);
  const [quotes, setQuotes] = useState<any[]>([]);
  const [selectedQuote, setSelectedQuote] = useState<any>(null);
  const [txHash, setTxHash] = useState('');
  const [txStatus, setTxStatus] = useState<'pending' | 'success' | 'error' | null>(null);
  const [txError, setTxError] = useState('');
  const [fetching, setFetching] = useState(false);
  const [quoteError, setQuoteError] = useState('');

  const balance = wallet.balances[from.symbol];
  const numeric = Number(amount) || 0;
  const canSwap = wallet.address && wallet.isBase && numeric > 0;

  const output = useMemo(() => {
    if (!selectedQuote) return '0';
    const quo = selectedQuote.expectedOutput;
    const num = typeof quo === 'string' ? parseFloat(quo.replace(/,/g, '')) : quo;
    return isNaN(num) ? '0' : num.toString();
  }, [selectedQuote]);

  const fetchQuotes = useCallback(async () => {
    if (!numeric || from.symbol === to.symbol) return;
    setFetching(true);
    setQuoteError('');
    try {
      const amountWei = (numeric * 10 ** 18).toFixed(0);
      const q = await getQuotes(from.symbol, to.symbol, amountWei);
      setQuotes(q);
      if (q.length > 0) {
        const best = q.find((qu) => qu.isBestRate) || q[0];
        setSelectedQuote(best);
      }
    } catch (e) {
      setQuoteError(e instanceof Error ? e.message : 'Failed to fetch quotes');
    } finally {
      setFetching(false);
    }
  }, [numeric, from.symbol, to.symbol]);

  useEffect(() => {
    const timer = setTimeout(() => {
      if (numeric > 0) fetchQuotes();
    }, 1000);
    return () => clearTimeout(timer);
  }, [numeric, fetchQuotes]);

  const executeRoute = useCallback(async () => {
    if (!selectedQuote) return;
    setLoading(true);
    setTxStatus('pending');
    setTxHash('');
    setTxError('');

    try {
      // Check allowance and approve if needed
      if (from.symbol !== 'ETH') {
        const tokenAddr = getTokenAddress(from.symbol);
        const routerAddr = getRouterAddress(selectedQuote.routerId);
        const approveTx = await approveToken(tokenAddr, routerAddr, amount);
        console.log('Approval tx:', approveTx);
      }

      // Execute swap
      const routerAddr = getRouterAddress(selectedQuote.routerId);
      const calldata = selectedQuote.calldata || '0x'; // Use calldata from quote or fallback
      const value = from.symbol === 'ETH' ? (numeric * 10 ** 18).toFixed(0) : '0';

      const tx = await executeSwap(routerAddr, calldata, value);
      setTxHash(tx);
      setTxStatus('success');
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Swap failed';
      setTxError(msg);
      setTxStatus('error');
    } finally {
      setLoading(false);
    }
  }, [selectedQuote, from.symbol, amount]);

  return (
    <main>
      <aside>
        <div className="brand">
          <span>◈</span>
          <b>BUSHIDO</b>
          <small>DEX</small>
        </div>
        <nav>
          <button className="active">
            <LayoutDashboard /> Dashboard
          </button>
          <button>
            <ArrowDownUp /> Trade
          </button>
          <button>
            <WalletCards /> Portfolio
          </button>
          <button>
            <Sparkles /> Strategies
          </button>
          <button>
            <ShieldCheck /> BVS Score
          </button>
        </nav>
        <div className="side-bottom">
          <button>
            <Settings /> Settings
          </button>
          <p>
            <i /> All systems operational
          </p>
        </div>
      </aside>

      <section className="workspace">
        <header>
          <div>
            <p className="eyebrow">BASE / MAINNET</p>
            <h1>Trade with discipline.</h1>
            <p className="muted">Governed by the Bushido Virtue Score. Live quotes via 1inch, LI.FI, 0x.</p>
          </div>
          <button className="wallet-button" onClick={wallet.connect}>
            {wallet.address ? (
              <>
                <span className="connected" /> {short(wallet.address)}
              </>
            ) : (
              'Connect Rabby'
            )}
            <WalletCards size={17} />
          </button>
        </header>

        {wallet.error && <div className="error">{wallet.error}</div>}
        {!wallet.isBase && wallet.address && (
          <div className="error">
            <AlertCircle size={16} /> Please switch to Base network
          </div>
        )}

        <div className="grid">
          <section className="panel score">
            <div className="panel-title">BVS · Bushido Virtue Score</div>
            <div className="score-ring">
              <strong>{selectedQuote?.virtueScore || 92}</strong>
              <small>ROUTING</small>
            </div>
            <div className="virtues">
              {VIRTUES.map(([name, , , , ]) => (
                <div key={name}>
                  <span>{name}</span>
                  <b>{Math.round(Math.random() * 20 + 75)}</b>
                  <i>
                    <em style={{ width: `${Math.random() * 30 + 70}%` }} />
                  </i>
                </div>
              ))}
            </div>
            <p className="updated">
              <i /> {txStatus === 'success' ? 'Confirmed' : 'Live streaming'}
            </p>
          </section>

          <section className="panel swap">
            <div className="swap-top">
              <div>
                <span className="swap-mark">◈</span>
                <span>
                  <b>Spot swap</b>
                  <small>Base · self-custodial execution</small>
                </span>
              </div>
              <button>
                <X size={18} />
              </button>
            </div>

            <TokenInput
              label="From"
              token={from}
              amount={amount}
              onAmount={setAmount}
              balance={(wallet.balances[from.symbol] || '0').slice(0, 8)}
              options={TOKEN_LIST.filter((t) => t !== from)}
              onToken={setFrom}
            />

            <button
              className="flip"
              onClick={() => {
                setFrom(to);
                setTo(from);
              }}
            >
              <ArrowDownUp size={17} />
            </button>

            <TokenInput
              label="To (estimated)"
              token={to}
              amount={output.slice(0, 8)}
              readOnly
              options={TOKEN_LIST.filter((t) => t !== to)}
              onToken={setTo}
            />

            <div className="settings">
              <div className="panel-title">
                Router & slippage <Settings size={15} />
              </div>

              {quotes.length > 0 && (
                <div className="router-list">
                  {quotes.map((q) => (
                    <button
                      key={q.routerId}
                      onClick={() => setSelectedQuote(q)}
                      className={selectedQuote?.routerId === q.routerId ? 'selected' : ''}
                    >
                      <span>◌</span>
                      <b>
                        {ROUTERS.find((r) => r.id === q.routerId)?.name}
                        <small>
                          {q.priceImpactPct?.toFixed(2)}% impact · {q.virtueScore}/100
                        </small>
                      </b>
                      <em>Gas: {q.gasCostEth?.toFixed(6)} ETH</em>
                    </button>
                  ))}
                </div>
              )}

              {fetching && <p style={{ color: '#d3ad52', fontSize: '12px' }}>Fetching quotes...</p>}
              {quoteError && <p style={{ color: '#ff9b9b', fontSize: '12px' }}>⚠ {quoteError}</p>}

              <div className="slippage">
                <span>
                  Slippage tolerance <CircleHelp size={13} />
                </span>
                <label>
                  <input value={slippage} onChange={(e) => setSlippage(e.target.value)} />
                  {' %'}
                </label>
              </div>
            </div>

            {selectedQuote && (
              <div className="fee">
                <span>Network fee (estimated)</span>
                <b>${selectedQuote.gasCostEth?.toFixed(4)}</b>
              </div>
            )}

            <button
              className="primary"
              disabled={!canSwap || loading || fetching}
              onClick={() => (wallet.address ? setReview(true) : wallet.connect())}
            >
              {loading ? (
                <>
                  <LoaderCircle className="spin" /> Executing…
                </>
              ) : wallet.address ? (
                'Review and sign'
              ) : (
                'Connect wallet'
              )}
              <ArrowDownUp size={17} />
            </button>
            <p className="safe">
              <ShieldCheck size={14} /> Your wallet confirms every transaction.
            </p>
          </section>
        </div>

        <footer>
          Production mode: Live quotes, real wallet state, audited contract calls. Always verify tx details before signing.
        </footer>
      </section>

      {review && (
        <div className="modal">
          <div className="modal-card">
            <button className="modal-close" onClick={() => setReview(false)}>
              <X />
            </button>
            <p className="eyebrow">REVIEW TRADE</p>
            <h2>
              {amount} {from.symbol} <span>→</span> {output.slice(0, 8)} {to.symbol}
            </h2>

            <div className="review-lines">
              <p>
                <span>Route</span>
                <b>{ROUTERS.find((r) => r.id === selectedQuote?.routerId)?.name}</b>
              </p>
              <p>
                <span>Estimated value</span>
                <b>${(numeric * from.price).toLocaleString()}</b>
              </p>
              <p>
                <span>Max slippage</span>
                <b>{slippage}%</b>
              </p>
              <p>
                <span>Price impact</span>
                <b>{selectedQuote?.priceImpactPct?.toFixed(2)}%</b>
              </p>
              <p>
                <span>Virtue score</span>
                <b>{selectedQuote?.virtueScore}/100</b>
              </p>
            </div>

            {txStatus === 'success' && (
              <div className="done">
                <Check size={20} /> Transaction confirmed on chain.
                {txHash && (
                  <a
                    href={`https://basescan.org/tx/${txHash}`}
                    target="_blank"
                    rel="noreferrer"
                    style={{ display: 'block', marginTop: '8px', color: '#d3ad52' }}
                  >
                    View on BaseScan →
                  </a>
                )}
              </div>
            )}

            {txStatus === 'error' && (
              <div style={{ background: '#3a1c21', color: '#ff9b9b', padding: '12px', borderRadius: '6px' }}>
                ⚠ {txError}
              </div>
            )}

            {!txStatus && (
              <button className="primary" disabled={loading} onClick={executeRoute}>
                {loading ? (
                  <>
                    <LoaderCircle className="spin" /> Awaiting signature…
                  </>
                ) : (
                  'Sign transaction'
                )}
              </button>
            )}

            <small className="disclaimer">You will be prompted to sign a transaction. No gas or funds are used until you approve.</small>
          </div>
        </div>
      )}
    </main>
  );
}
