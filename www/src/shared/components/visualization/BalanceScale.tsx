import React from 'react';
import './styles/BalanceScale.scss';

// ── Tunables ──────────────────────────────────────────────────────

const REPEAT_COUNT = 4;
const SWING_DUR = '4s';
const ARM_DUR = '2s';
const SETTLE_DUR = '1s';
const SWING_RANGE = 10;

const WIDTH = 400;
const HEIGHT = 300;
const PIVOT_X = 200;
const PIVOT_Y = 50;
const ARM_HALF = 100;
const STRING_LEN = 50;
const PAN_W = 60;
const PAN_H = 30;

const LEFT_LABEL = 'IPv4';
const RIGHT_LABEL = 'IPv6';
const LABEL_Y = PIVOT_Y + STRING_LEN + PAN_H + 40;

// ── Component ─────────────────────────────────────────────────────

const BalanceScale: React.FC = () => {
  const rc = String(REPEAT_COUNT);
  const leftX = -ARM_HALF;
  const rightX = ARM_HALF;
  const panY = STRING_LEN;
  const panHalfW = PAN_W / 2;

  return (
    <div className="balance-scale" data-testid="vpn-net-balance-scale">
      <svg
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        width={WIDTH}
        height={HEIGHT}
        xmlns="http://www.w3.org/2000/svg"
        aria-label="Balance scale diagram"
        className="balance-scale__svg"
      >
        <defs>
          <symbol id="icon-network" viewBox="0 0 32 32">
            <title>network</title>
            <circle cx="21" cy="26" r="2" />
            <circle cx="21" cy="6" r="2" />
            <circle cx="4" cy="16" r="2" />
            <path d="M28,12a3.9962,3.9962,0,0,0-3.8579,3H19.8579a3.9655,3.9655,0,0,0-5.4914-2.6426L11.19,8.3872A3.9626,3.9626,0,0,0,12,6a4,4,0,1,0-4,4,3.96,3.96,0,0,0,1.6338-.3574l3.176,3.97a3.9239,3.9239,0,0,0,0,4.7744l-3.1758,3.97A3.96,3.96,0,0,0,8,22a4,4,0,1,0,4,4,3.9624,3.9624,0,0,0-.81-2.3872l3.1758-3.97A3.9658,3.9658,0,0,0,19.8579,17h4.2842A3.9934,3.9934,0,1,0,28,12zM6,6A2,2,0,1,1,8,8,2.0023,2.0023,0,0,1,6,6zM8,28a2,2,0,1,1,2-2A2.0023,2.0023,0,0,1,8,28zm8-10a2,2,0,1,1,2-2A2.0023,2.0023,0,0,1,16,18zm12,0a2,2,0,1,1,2-2A2.0023,2.0023,0,0,1,28,18z" />
          </symbol>
        </defs>

        {/* Guide lines */}
        <line
          className="balance-scale__guide"
          x1={PIVOT_X}
          y1={HEIGHT - 50}
          x2={PIVOT_X}
          y2={PIVOT_Y}
        />
        <line
          className="balance-scale__guide"
          x1={PIVOT_X - ARM_HALF}
          y1={PIVOT_Y}
          x2={PIVOT_X + ARM_HALF}
          y2={PIVOT_Y}
        />

        {/* Balance arm */}
        <g transform={`translate(${PIVOT_X},${PIVOT_Y})`}>
          <rect
            className="balance-scale__arm"
            x={-ARM_HALF}
            y="-5"
            width={ARM_HALF * 2}
            height="10"
          />

          {/* Left pan */}
          <g transform={`translate(${leftX},${panY})`}>
            <rect
              className="balance-scale__pan balance-scale__pan--left"
              x={-panHalfW}
              y="0"
              width={PAN_W}
              height={PAN_H}
            />
            <g transform="translate(-8,7) scale(0.5)">
              <use href="#icon-network" width="32" height="32" className="balance-scale__icon" />
            </g>
            <line className="balance-scale__string" x1="0" y1="0" x2="0" y2={-STRING_LEN} />
            <animateTransform
              attributeName="transform"
              type="translate"
              values={`${leftX},${panY}; ${leftX},${panY + SWING_RANGE}; ${leftX},${panY - SWING_RANGE}; ${leftX},${panY}`}
              dur={SWING_DUR}
              repeatCount={rc}
              fill="freeze"
            />
          </g>

          {/* Right pan */}
          <g transform={`translate(${rightX},${panY})`}>
            <rect
              className="balance-scale__pan balance-scale__pan--right"
              x={-panHalfW}
              y="0"
              width={PAN_W}
              height={PAN_H}
            />
            <g transform="translate(-8,7) scale(0.5)">
              <use href="#icon-network" width="32" height="32" className="balance-scale__icon" />
            </g>
            <line className="balance-scale__string" x1="0" y1="0" x2="0" y2={-STRING_LEN} />
            <animateTransform
              attributeName="transform"
              type="translate"
              values={`${rightX},${panY}; ${rightX},${panY - SWING_RANGE}; ${rightX},${panY + SWING_RANGE}; ${rightX},${panY}`}
              dur={SWING_DUR}
              repeatCount={rc}
              fill="freeze"
            />
          </g>

          {/* Arm rotation */}
          <animateTransform
            attributeName="transform"
            attributeType="XML"
            type="rotate"
            begin="0s"
            dur={ARM_DUR}
            repeatCount={rc}
            fill="freeze"
          />
          <animateTransform
            attributeName="transform"
            attributeType="XML"
            type="rotate"
            begin="2s"
            dur={ARM_DUR}
            repeatCount={rc}
            fill="freeze"
          />
          <animateTransform
            attributeName="transform"
            attributeType="XML"
            type="rotate"
            begin="4s"
            dur={SETTLE_DUR}
            repeatCount={rc}
            fill="freeze"
          />
        </g>

        {/* Labels */}
        <text
          className="balance-scale__label"
          x={PIVOT_X - ARM_HALF}
          y={LABEL_Y}
          textAnchor="middle"
        >
          {LEFT_LABEL}
        </text>
        <text
          className="balance-scale__label"
          x={PIVOT_X + ARM_HALF}
          y={LABEL_Y}
          textAnchor="middle"
        >
          {RIGHT_LABEL}
        </text>
      </svg>
    </div>
  );
};

export default BalanceScale;
