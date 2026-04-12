/**
 * ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
 * ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
 * ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
 * ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
 * ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
 * ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
 * Phantom Asset Generator Service
 * Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
 */

const fs = require('fs');
const path = require('path');
const sharp = require('sharp');
const pngToIco = require('png-to-ico');

// ============================================================================
// COMMAND LINE ARGUMENTS
// ============================================================================
const args = process.argv.slice(2);
const outputDirArg = args[0] || './output';

// ============================================================================
// CONFIGURATION
// ============================================================================
const CONFIG = {
  inputDir: './masters',  // Fixed input directory
  outputDir: outputDirArg,
  masterFiles: [
    'phantom-horizontal-master.svg',
    'phantom-vertical-master.svg',
    'phantom-icon-master.svg'
  ],
  iconMasterFile: 'phantom-icon-master.svg',
  iconFormats: ['png', 'webp', 'avif'],
  icoSizes: [16, 32, 48], // Standard favicon sizes only

  // Logo configurations
  logoFiles: {
    horizontal: 'phantom-horizontal-master.svg',
    vertical: 'phantom-vertical-master.svg'
  },
  logoFormats: ['png', 'webp', 'avif'],

  // Logo sizes for different use cases
  logoSizes: {
    horizontal: [
      { width: 200, name: 'logo-h-small' },
      { width: 300, name: 'logo-h-medium' },
      { width: 400, name: 'logo-h-large' },
      { width: 600, name: 'logo-h-xlarge' }
    ],
    vertical: [
      { height: 150, name: 'logo-v-small' },
      { height: 200, name: 'logo-v-medium' },
      { height: 300, name: 'logo-v-large' },
      { height: 400, name: 'logo-v-xlarge' }
    ]
  },

  // Icon sizes for different platforms
  iconSizes: {
    favicons: [
      { size: 16, name: 'favicon-16' },
      { size: 32, name: 'favicon-32' },
      { size: 48, name: 'favicon-48' },
      { size: 96, name: 'favicon-96' },
      { size: 192, name: 'favicon-192' }
    ],
    ios: [
      { size: 180, name: 'apple-touch-icon-180' },
      { size: 152, name: 'apple-touch-icon-152' },
      { size: 120, name: 'apple-touch-icon-120' },
      { size: 76, name: 'apple-touch-icon-76' },
      { size: 60, name: 'apple-touch-icon-60' }
    ],
    android: [
      { size: 512, name: 'android-chrome-512' },
      { size: 192, name: 'android-chrome-192' },
      { size: 144, name: 'android-chrome-144' },
      { size: 96, name: 'android-chrome-96' },
      { size: 72, name: 'android-chrome-72' },
      { size: 48, name: 'android-chrome-48' }
    ]
  }
};

// ============================================================================
// COLOR THEMES
// ============================================================================
const COLOR_THEMES = {
  'midnight-phantom': {
    name: 'Midnight Phantom',
    description: 'Default deep space purple',
    colors: {
      shield: '#24245a',
      ghost: '#ffffff',
      eyes: '#24245a',
      text: '#24245a',
      slogan: '#5c5981'
    }
  },
  'quantum-blue': {
    name: 'Quantum Blue',
    description: 'Deep space blue for tech community',
    colors: {
      shield: '#0A1628',
      ghost: '#ffffff',
      eyes: '#1E3A8A',
      text: '#0A1628',
      slogan: '#60A5FA'
    }
  },
  'forest-stealth': {
    name: 'Forest Stealth',
    description: 'Eco-tech, green computing',
    colors: {
      shield: '#14532D',
      ghost: '#ffffff',
      eyes: '#166534',
      text: '#14532D',
      slogan: '#4ADE80'
    }
  },
  'dark-matter': {
    name: 'Dark Matter',
    description: 'Near black minimalist design',
    colors: {
      shield: '#0F0F0F',
      ghost: '#ffffff',
      eyes: '#1A1A1A',
      text: '#0F0F0F',
      slogan: '#707070'
    }
  },
  'void-black': {
    name: 'Void Black',
    description: 'Absolute black monochrome',
    colors: {
      shield: '#000000',
      ghost: '#ffffff',
      eyes: '#000000',
      text: '#000000',
      slogan: '#666666'
    }
  },
  'crimson-phantom': {
    name: 'Crimson Phantom',
    description: 'Warning red for security alerts',
    colors: {
      shield: '#1A0A0A',
      ghost: '#ffffff',
      eyes: '#DC2626',
      text: '#1A0A0A',
      slogan: '#EF4444'
    }
  },
  'mystic-purple': {
    name: 'Mystic Purple',
    description: 'Deep cosmic purple energy',
    colors: {
      shield: '#3B0764',
      ghost: '#ffffff',
      eyes: '#7C3AED',
      text: '#3B0764',
      slogan: '#A78BFA'
    }
  },
  'stellar-silver': {
    name: 'Stellar Silver',
    description: 'Light mode inverted design',
    colors: {
      shield: '#E5E7EB',
      ghost: '#1F2937',
      eyes: '#E5E7EB',
      text: '#E5E7EB',
      slogan: '#9CA3AF'
    }
  }
};

// ============================================================================
// MAIN EXECUTION
// ============================================================================
async function main() {
  console.log('=================================================');
  console.log('Phantom Asset Generator');
  console.log('=================================================\n');

  // Show help if requested
  if (args[0] === '--help' || args[0] === '-h') {
    showHelp();
    process.exit(0);
  }

  console.log(`Input directory: ${CONFIG.inputDir}`);
  console.log(`Output directory: ${CONFIG.outputDir}\n`);

  // Verify input directory exists
  if (!fs.existsSync(CONFIG.inputDir)) {
    console.error(`[ERROR] Input directory not found: ${CONFIG.inputDir}`);
    console.log('Please create the ./masters directory with the required SVG files.');
    console.log('\nUsage: node generate-assets.js [outputDir]');
    console.log('Run with --help for more information.');
    process.exit(1);
  }

  // Ensure output directory exists
  ensureDirectoryExists(CONFIG.outputDir);

  let totalSVGGenerated = 0;
  let totalSVGSkipped = 0;
  let totalIconsGenerated = 0;
  let totalIconsFailed = 0;
  let totalLogosGenerated = 0;
  let totalLogosFailed = 0;

  // Generate assets for each theme
  console.log('Generating assets...\n');

  for (const [themeName, themeData] of Object.entries(COLOR_THEMES)) {
    console.log(`Theme: ${themeData.name} (${themeName})`);
    console.log(`Description: ${themeData.description}`);

    let themeIconSvgContent = null;
    let themeHorizontalSvgContent = null;
    let themeVerticalSvgContent = null;

    // Generate SVG variations
    for (const masterFile of CONFIG.masterFiles) {
      const { success, svgContent } = generateColorVariation(masterFile, themeName, themeData);

      if (success) {
        console.log(`  [OK] ${masterFile}`);
        totalSVGGenerated++;

        // Store SVG content for different generation purposes
        if (masterFile === CONFIG.iconMasterFile) {
          themeIconSvgContent = svgContent;
        } else if (masterFile === CONFIG.logoFiles.horizontal) {
          themeHorizontalSvgContent = svgContent;
        } else if (masterFile === CONFIG.logoFiles.vertical) {
          themeVerticalSvgContent = svgContent;
        }
      } else {
        console.log(`  [SKIP] ${masterFile}`);
        totalSVGSkipped++;
      }
    }

    // Generate icons from the icon master SVG
    if (themeIconSvgContent) {
      console.log('  Generating icons...');
      const { generated, failed } = await generateThemeIcons(themeIconSvgContent, themeName);
      console.log(`  [DONE] Generated ${generated} icons${failed > 0 ? ` (${failed} failed)` : ''}`);
      totalIconsGenerated += generated;
      totalIconsFailed += failed;
    }

    // Generate logos from horizontal and vertical SVGs
    if (themeHorizontalSvgContent || themeVerticalSvgContent) {
      console.log('  Generating logos...');
      const { generated, failed } = await generateThemeLogos(themeHorizontalSvgContent, themeVerticalSvgContent, themeName);
      console.log(`  [DONE] Generated ${generated} logos${failed > 0 ? ` (${failed} failed)` : ''}`);
      totalLogosGenerated += generated;
      totalLogosFailed += failed;
    }

    console.log('');
  }

  // Generate summary file
  const summaryPath = path.join(CONFIG.outputDir, 'asset-summary.json');
  const summary = createSummary(totalSVGGenerated, totalSVGSkipped, totalIconsGenerated, totalIconsFailed, totalLogosGenerated, totalLogosFailed);

  try {
    fs.writeFileSync(summaryPath, JSON.stringify(summary, null, 2));
  } catch (error) {
    console.warn(`[WARNING] Could not write summary file: ${error.message}`);
  }

  // Display summary
  displaySummary(totalSVGGenerated, totalSVGSkipped, totalIconsGenerated, totalIconsFailed, totalLogosGenerated, totalLogosFailed, summaryPath);
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

function showHelp() {
  console.log('Usage: node generate-assets.js [outputDir]');
  console.log('\nArguments:');
  console.log('  outputDir   Output directory for assets (default: ./output)');
  console.log('\nExamples:');
  console.log('  node generate-assets.js');
  console.log('  node generate-assets.js ./my-output');
  console.log('\nExpected master files in ./masters/:');
  CONFIG.masterFiles.forEach(file => console.log(`  - ${file}`));
  console.log('\nGenerated assets:');
  console.log('  - Color variations for each SVG');
  console.log('  - Icons in PNG, WebP, AVIF formats');
  console.log('  - Multi-resolution favicon.ico');
  console.log('  - Horizontal logos in multiple sizes');
  console.log('  - Vertical logos in multiple sizes');
}

function ensureDirectoryExists(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function replaceColors(svgContent, colorMap) {
  let result = svgContent;

  // Replace colors for each CSS class
  Object.entries(colorMap).forEach(([className, color]) => {
    if (color) {
      const regex = new RegExp(`\\.${className}\\s*{\\s*fill:\\s*#[0-9a-fA-F]{6};`, 'g');
      result = result.replace(regex, `.${className} { fill: ${color};`);
    }
  });

  return result;
}

function generateColorVariation(masterFile, themeName, themeData) {
  const inputPath = path.join(CONFIG.inputDir, masterFile);
  const outputThemeDir = path.join(CONFIG.outputDir, themeName);
  const outputPath = path.join(outputThemeDir, masterFile);

  // Read master SVG
  if (!fs.existsSync(inputPath)) {
    return { success: false, svgContent: null };
  }

  let svgContent = fs.readFileSync(inputPath, 'utf8');

  // Replace colors
  svgContent = replaceColors(svgContent, themeData.colors);

  // Ensure output directory exists
  ensureDirectoryExists(outputThemeDir);

  // Write output file
  fs.writeFileSync(outputPath, svgContent, 'utf8');

  return { success: true, svgContent };
}

async function generateIcon(inputBuffer, outputPath, size, format = 'png') {
  try {
    const sharpInstance = sharp(inputBuffer)
      .resize(size, size, {
        fit: 'contain',
        background: { r: 0, g: 0, b: 0, alpha: 0 }
      });

    switch (format) {
      case 'png':
        await sharpInstance.png({ quality: 100 }).toFile(`${outputPath}.png`);
        break;
      case 'webp':
        await sharpInstance.webp({ quality: 100, lossless: true }).toFile(`${outputPath}.webp`);
        break;
      case 'avif':
        await sharpInstance.avif({ quality: 100, lossless: true }).toFile(`${outputPath}.avif`);
        break;
      default:
        console.warn(`[WARNING] Unknown format: ${format}`);
        return false;
    }

    return true;
  } catch (error) {
    console.error(`[ERROR] Failed to generate ${path.basename(outputPath)}.${format}: ${error.message}`);
    return false;
  }
}

async function generateLogo(inputBuffer, outputPath, dimensions, format = 'png') {
  try {
    // Determine resize options based on whether width or height is specified
    const resizeOptions = dimensions.width
      ? { width: dimensions.width, fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } }
      : { height: dimensions.height, fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } };

    const sharpInstance = sharp(inputBuffer).resize(resizeOptions);

    switch (format) {
      case 'png':
        await sharpInstance.png({ quality: 100 }).toFile(`${outputPath}.png`);
        break;
      case 'webp':
        await sharpInstance.webp({ quality: 100, lossless: true }).toFile(`${outputPath}.webp`);
        break;
      case 'avif':
        await sharpInstance.avif({ quality: 100, lossless: true }).toFile(`${outputPath}.avif`);
        break;
      default:
        console.warn(`[WARNING] Unknown format: ${format}`);
        return false;
    }

    return true;
  } catch (error) {
    console.error(`[ERROR] Failed to generate ${path.basename(outputPath)}.${format}: ${error.message}`);
    return false;
  }
}

async function generateIcoFile(inputBuffer, outputPath) {
  try {
    const buffers = [];

    // Use only standard favicon sizes to reduce file size
    for (const size of CONFIG.icoSizes) {
      const buffer = await sharp(inputBuffer)
        .resize(size, size, {
          fit: 'contain',
          background: { r: 0, g: 0, b: 0, alpha: 0 }
        })
        .png({ compressionLevel: 9 })  // Maximum compression
        .toBuffer();
      buffers.push(buffer);
    }

    const icoBuffer = await pngToIco(buffers);
    fs.writeFileSync(outputPath, icoBuffer);
    return true;
  } catch (error) {
    console.error(`[ERROR] Failed to generate ICO file: ${error.message}`);
    return false;
  }
}

async function generateCategoryIcons(svgBuffer, category, sizes, formats, outputDir) {
  const categoryDir = path.join(outputDir, category);
  ensureDirectoryExists(categoryDir);

  let generated = 0;
  let failed = 0;

  for (const { size, name } of sizes) {
    for (const format of formats) {
      const outputPath = path.join(categoryDir, name);
      const success = await generateIcon(svgBuffer, outputPath, size, format);

      if (success) {
        generated++;
      } else {
        failed++;
      }
    }
  }

  return { generated, failed };
}

async function generateThemeIcons(svgContent, themeName) {
  const iconsDir = path.join(CONFIG.outputDir, themeName, 'icons');
  ensureDirectoryExists(iconsDir);

  let totalGenerated = 0;
  let totalFailed = 0;

  const svgBuffer = Buffer.from(svgContent);

  // Generate icons for each category
  for (const [category, sizes] of Object.entries(CONFIG.iconSizes)) {
    const { generated, failed } = await generateCategoryIcons(
      svgBuffer,
      category,
      sizes,
      CONFIG.iconFormats,
      iconsDir
    );
    totalGenerated += generated;
    totalFailed += failed;
  }

  // Generate favicon.ico
  const faviconDir = path.join(iconsDir, 'favicons');
  const icoPath = path.join(faviconDir, 'favicon.ico');
  const icoSuccess = await generateIcoFile(svgBuffer, icoPath);

  if (icoSuccess) {
    totalGenerated++;
  } else {
    totalFailed++;
  }

  return { generated: totalGenerated, failed: totalFailed };
}

async function generateThemeLogos(horizontalSvgContent, verticalSvgContent, themeName) {
  const logosDir = path.join(CONFIG.outputDir, themeName, 'logos');
  ensureDirectoryExists(logosDir);

  let totalGenerated = 0;
  let totalFailed = 0;

  // Generate horizontal logos
  if (horizontalSvgContent) {
    const horizontalDir = path.join(logosDir, 'horizontal');
    ensureDirectoryExists(horizontalDir);
    const horizontalBuffer = Buffer.from(horizontalSvgContent);

    for (const logoSize of CONFIG.logoSizes.horizontal) {
      for (const format of CONFIG.logoFormats) {
        const outputPath = path.join(horizontalDir, logoSize.name);
        const success = await generateLogo(horizontalBuffer, outputPath, logoSize, format);
        if (success) {
          totalGenerated++;
        } else {
          totalFailed++;
        }
      }
    }
  }

  // Generate vertical logos
  if (verticalSvgContent) {
    const verticalDir = path.join(logosDir, 'vertical');
    ensureDirectoryExists(verticalDir);
    const verticalBuffer = Buffer.from(verticalSvgContent);

    for (const logoSize of CONFIG.logoSizes.vertical) {
      for (const format of CONFIG.logoFormats) {
        const outputPath = path.join(verticalDir, logoSize.name);
        const success = await generateLogo(verticalBuffer, outputPath, logoSize, format);
        if (success) {
          totalGenerated++;
        } else {
          totalFailed++;
        }
      }
    }
  }

  return { generated: totalGenerated, failed: totalFailed };
}

function createSummary(svgGenerated, svgSkipped, iconsGenerated, iconsFailed, logosGenerated, logosFailed) {
  return {
    generated: new Date().toISOString(),
    svgFiles: {
      generated: svgGenerated,
      skipped: svgSkipped
    },
    icons: {
      generated: iconsGenerated,
      failed: iconsFailed,
      formats: CONFIG.iconFormats,
      categories: Object.keys(CONFIG.iconSizes)
    },
    logos: {
      generated: logosGenerated,
      failed: logosFailed,
      formats: CONFIG.logoFormats,
      types: Object.keys(CONFIG.logoSizes)
    },
    themes: Object.keys(COLOR_THEMES),
    outputDirectory: CONFIG.outputDir
  };
}

function displaySummary(svgGenerated, svgSkipped, iconsGenerated, iconsFailed, logosGenerated, logosFailed, summaryPath) {
  console.log('=================================================');
  console.log('Generation Complete');
  console.log('=================================================');
  console.log(`SVG files generated: ${svgGenerated}`);
  if (svgSkipped > 0) console.log(`SVG files skipped: ${svgSkipped}`);
  console.log(`Icons generated: ${iconsGenerated}`);
  if (iconsFailed > 0) console.log(`Icons failed: ${iconsFailed}`);
  console.log(`Logos generated: ${logosGenerated}`);
  if (logosFailed > 0) console.log(`Logos failed: ${logosFailed}`);
  console.log(`Output directory: ${CONFIG.outputDir}`);
  console.log('\nColor themes generated:');
  Object.keys(COLOR_THEMES).forEach(themeName => {
    console.log(`  - ${themeName}`);
  });
  console.log(`\nSummary file: ${summaryPath}`);
}

// ============================================================================
// SCRIPT EXECUTION
// ============================================================================

if (require.main === module) {
  main().catch(error => {
    console.error(`\n[FATAL ERROR] ${error.message}`);
    process.exit(1);
  });
}

module.exports = { COLOR_THEMES, CONFIG };