import { useEffect, useState, RefObject } from 'react';
import type { GameEngine } from '../engine/GameEngine';
import { GameState } from '../types';

export function useKeyboardInput(
  gameEngine: GameEngine | null,
  containerRef: RefObject<HTMLElement | null>,
  gameState: GameState
) {
  const [isVisible, setIsVisible] = useState(true);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const observer = new IntersectionObserver(([entry]) => setIsVisible(entry.isIntersecting), {
      threshold: 1,
    });

    observer.observe(container);
    return () => observer.disconnect();
  }, [containerRef]);

  useEffect(() => {
    if (!gameEngine || !isVisible) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.code === 'ArrowUp' && gameState === GameState.RUNNING) {
        e.preventDefault();
        gameEngine.jump();
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [gameEngine, isVisible, gameState]);
}