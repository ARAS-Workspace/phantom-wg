import React, { useEffect, useRef, useState, useMemo } from 'react';
import { Grid, Column } from '@carbon/react';
import { GameEngine, type GameRenderState } from './engine/GameEngine';
import { GameState } from './types';
import { useKeyboardInput } from './hooks/useKeyboardInput';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { getThemeIcons, getVariantCounts } from './assets/themes/iconMap';
import type { ThemeName } from './assets/themes';
import { GAME_AREA } from './constants';
import './styles/DinoGame.scss';

export interface DinoGameProps {
  theme?: ThemeName;
}

const DinoGame: React.FC<DinoGameProps> = ({ theme = 'error' }) => {
  const containerRef = useRef<HTMLDivElement>(null);
  const [gameEngine, setGameEngine] = useState<GameEngine | null>(null);
  const [renderState, setRenderState] = useState<GameRenderState | null>(null);
  const { locale } = useLocale();
  const t = translate(locale);
  const themeIcons = useMemo(() => getThemeIcons(theme), [theme]);
  const variantCounts = useMemo(() => getVariantCounts(themeIcons), [themeIcons]);

  const messages = useMemo(
    () => ({
      startMessage: t.dinoGame.startMessage,
      gameOver: t.dinoGame.gameOver,
      restartMessage: t.dinoGame.restartMessage,
      score: t.dinoGame.score,
    }),
    [t]
  );

  useEffect(() => {
    const engine = new GameEngine(messages, variantCounts);
    setGameEngine(engine);
    setRenderState(engine.getState());
    return () => setGameEngine(null);
  }, [messages, variantCounts]);

  useEffect(() => {
    if (!gameEngine) return;
    let animationId: number;
    const gameLoop = () => {
      gameEngine.update();
      setRenderState(gameEngine.getState());
      animationId = requestAnimationFrame(gameLoop);
    };
    animationId = requestAnimationFrame(gameLoop);
    return () => { if (animationId) cancelAnimationFrame(animationId); };
  }, [gameEngine]);

  useKeyboardInput(gameEngine, containerRef, renderState?.state ?? GameState.WAITING);

  useEffect(() => {
    if (!gameEngine || !containerRef.current) return;
    const container = containerRef.current;
    const handleInteraction = (e: Event) => { e.preventDefault(); gameEngine.jump(); };
    container.addEventListener('click', handleInteraction);
    container.addEventListener('touchstart', handleInteraction, { passive: false });
    return () => {
      container.removeEventListener('click', handleInteraction);
      container.removeEventListener('touchstart', handleInteraction);
    };
  }, [gameEngine]);

  if (!renderState) return null;

  const DinoIcon = themeIcons.dino;

  return (
    <Grid>
      <Column sm={4} md={8} lg={16}>
        <div
          ref={containerRef}
          className="dino-game"
          style={{
            position: 'relative',
            height: `${GAME_AREA.HEIGHT}px`,
            width: `${GAME_AREA.WIDTH}px`,
            maxWidth: '100%',
            margin: '0 auto',
          }}
        >
          <div className="dino-game__ground" />

          {renderState.clouds.map((cloud, idx) => {
            const CloudIcon = themeIcons.clouds[cloud.variantIndex] || themeIcons.clouds[0];
            return (
              <div
                key={`cloud-${idx}`}
                className="dino-game__cloud"
                style={{ transform: `translate(${cloud.x}px, ${cloud.y}px)`, width: `${cloud.width}px`, height: `${cloud.height}px` }}
              >
                <CloudIcon size={cloud.width} className="dino-game__icon dino-game__icon--cloud" />
              </div>
            );
          })}

          <div
            className="dino-game__dino"
            style={{ transform: `translate(${renderState.dino.x}px, ${renderState.dino.y}px)`, width: `${renderState.dino.width}px`, height: `${renderState.dino.height}px` }}
          >
            <DinoIcon size={renderState.dino.width} className="dino-game__icon dino-game__icon--dino" />
          </div>

          {renderState.obstacles.map((obstacle, idx) => {
            const ObstacleIcon = themeIcons.obstacles[obstacle.variantIndex] || themeIcons.obstacles[0];
            return (
              <div
                key={`obstacle-${idx}`}
                className="dino-game__obstacle"
                style={{ transform: `translate(${obstacle.x}px, ${obstacle.y}px)`, width: `${obstacle.width}px`, height: `${obstacle.height}px` }}
              >
                <ObstacleIcon size={obstacle.width} className="dino-game__icon dino-game__icon--obstacle" />
              </div>
            );
          })}

          <div className="dino-game__score">{String(renderState.score).padStart(5, '0')}</div>

          {renderState.state === GameState.WAITING && (
            <div className="dino-game__message">{renderState.messages.startMessage}</div>
          )}
          {renderState.state === GameState.CRASHED && (
            <div className="dino-game__message">
              <div className="dino-game__message-title">{renderState.messages.gameOver}</div>
              <div className="dino-game__message-subtitle">{renderState.messages.restartMessage}</div>
            </div>
          )}
        </div>
      </Column>
    </Grid>
  );
};

export default DinoGame;
