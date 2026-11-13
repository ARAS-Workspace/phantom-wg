import React from 'react';
import { useNavigate } from 'react-router-dom';
import { Button } from '@carbon/react';
import { ArrowLeft, Construction, LogoGithub } from '@carbon/icons-react';
import type { CarbonIconType } from '@carbon/icons-react';
import DinoGame from '@shared/components/games/DinoGame';
import './styles/UnderConstruction.scss';

export interface UnderConstructionAction {
  title: string;
  href: string;
  external?: boolean;
  icon?: string;
}

const ICON_MAP: Record<string, CarbonIconType> = {
  'arrow-left': ArrowLeft,
  'github': LogoGithub,
};

export interface UnderConstructionContent {
  title: string;
  description: string;
  actions: UnderConstructionAction[];
}

export interface UnderConstructionProps {
  content: UnderConstructionContent;
}

const UnderConstruction: React.FC<UnderConstructionProps> = ({ content }) => {
  const navigate = useNavigate();

  return (
    <section className="under-construction">
      <div className="under-construction__content">
        <div className="under-construction__icon-wrapper">
          <Construction className="under-construction__icon" />
        </div>
        <h1 className="under-construction__title">{content.title}</h1>
        <p className="under-construction__description">{content.description}</p>
        <div className="under-construction__game">
          <DinoGame.Lazy theme="under-construction" />
        </div>
        <div className="under-construction__actions">
          {content.actions.map((action, index) => (
            <Button
              key={action.href}
              kind={index === 0 ? 'primary' : 'ghost'}
              size="lg"
              href={action.href}
              renderIcon={action.icon ? ICON_MAP[action.icon] : undefined}
              {...(action.external
                ? { target: '_blank', rel: 'noopener noreferrer' }
                : { onClick: (e: React.MouseEvent) => { e.preventDefault(); navigate(action.href); } })}
            >
              {action.title}
            </Button>
          ))}
        </div>
      </div>
    </section>
  );
};

export default UnderConstruction;
