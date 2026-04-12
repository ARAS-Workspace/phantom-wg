import React from 'react';
import { Grid, Column, ClickableTile } from '@carbon/react';
import { ArrowRight, ContainerServices, BareMetalServer } from '@carbon/icons-react';
import type { CarbonIconType } from '@carbon/icons-react';
import PhantomIcon from './PhantomIcon';
import './styles/Hero.scss';

export interface VersionTile {
  title: string;
  description: string;
  href: string;
  external?: boolean;
  icon?: string;
}

const ICON_MAP: Record<string, CarbonIconType> = {
  'container': ContainerServices,
  'bare-metal': BareMetalServer,
};

export interface HeroContent {
  title: string;
  subtitle: string;
  description: string;
  versions: VersionTile[];
}

export interface HeroProps {
  content: HeroContent;
}

const Hero: React.FC<HeroProps> = ({ content }) => {
  return (
    <section className="hero-section">
      <Grid className="hero-grid">
        <Column xlg={6} lg={16} md={8} sm={4} className="hero-visual-column">
          <div className="hero-visual">
            <PhantomIcon className="hero-visual-image" />
          </div>
        </Column>

        <Column xlg={10} lg={16} md={8} sm={4} className="hero-content-column">
          <div className="hero-content">
            <h1 className="hero-title">{content.title}</h1>
            <p className="hero-subtitle">{content.subtitle}</p>
            <p className="hero-description">{content.description}</p>
            <div className="hero-versions">
              {content.versions.map((version) => (
                <ClickableTile
                  key={version.href}
                  className="hero-version-tile"
                  href={version.href}
                  {...(version.external ? { target: '_blank', rel: 'noopener noreferrer' } : {})}
                >
                  <div className="hero-version-tile__content">
                    {version.icon && ICON_MAP[version.icon] && (
                      (() => { const Icon = ICON_MAP[version.icon!]; return <Icon size={32} className="hero-version-tile__icon" />; })()
                    )}
                    <div className="hero-version-tile__text">
                      <p className="hero-version-tile__title">{version.title}</p>
                      <p className="hero-version-tile__desc">{version.description}</p>
                    </div>
                    <ArrowRight size={20} className="hero-version-tile__arrow" />
                  </div>
                </ClickableTile>
              ))}
            </div>
          </div>
        </Column>
      </Grid>
    </section>
  );
};

export default Hero;
