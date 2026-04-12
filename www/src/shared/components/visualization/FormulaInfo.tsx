import React, { useState } from 'react';
import { Information } from '@carbon/icons-react';
import './styles/FormulaInfo.scss';

// ── Types ─────────────────────────────────────────────────────────

interface SymbolDefinition {
  symbol: string;
  description: string;
}

interface FormulaEntry {
  formula: string;
  title: string;
  symbols: SymbolDefinition[];
  summary?: string;
}

interface FormulaInfoProps {
  formulas: FormulaEntry[];
}

// ── Component ─────────────────────────────────────────────────────

const FormulaInfo: React.FC<FormulaInfoProps> = ({ formulas }) => {
  const [openIndex, setOpenIndex] = useState<number | null>(null);

  const toggle = (idx: number) => {
    setOpenIndex(openIndex === idx ? null : idx);
  };

  return (
    <div className="formula-info" data-testid="docs-formula-info">
      {formulas.map((entry, idx) => (
        <div className="formula-info__entry" key={idx}>
          <button
            type="button"
            className={`formula-info__row${openIndex === idx ? ' formula-info__row--open' : ''}`}
            onClick={() => toggle(idx)}
            aria-expanded={openIndex === idx}
          >
            <code className="formula-info__formula">{entry.formula}</code>
            <Information size={18} className="formula-info__icon" />
          </button>

          {openIndex === idx && (
            <div className="formula-info__detail">
              <p className="formula-info__title">{entry.title}</p>
              <ul className="formula-info__list">
                {entry.symbols.map((sym, si) => (
                  <li key={si}>
                    <code>{sym.symbol}</code> — {sym.description}
                  </li>
                ))}
              </ul>
              {entry.summary && (
                <p className="formula-info__summary">{entry.summary}</p>
              )}
            </div>
          )}
        </div>
      ))}
    </div>
  );
};

export default FormulaInfo;
