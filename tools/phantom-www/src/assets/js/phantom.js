/**
 * Phantom-WG JavaScript
 * Main application logic for the Phantom landing page
 */

// ============================
// Page Loader Management
// ============================
class PhantomPageLoader {
    constructor() {
        this.loader = document.getElementById('pageLoader');
        this.progressBar = this.loader?.querySelector('.loader-progress-bar');
        this.loaderText = this.loader?.querySelector('.loader-text');
        this.progress = 0;
        this.loadingSteps = [
            { progress: 10, text: 'Loading Assets' },
            { progress: 30, text: 'Loading Fonts' },
            { progress: 50, text: 'Loading Scripts' },
            { progress: 70, text: 'Initializing' },
            { progress: 90, text: 'Almost Ready' },
            { progress: 100, text: 'Complete' }
        ];
    }

    updateProgress(progress, text) {
        if (this.progressBar) {
            this.progressBar.style.width = `${progress}%`;
        }
        if (this.loaderText && text) {
            this.loaderText.textContent = text;
        }
    }

    async simulateLoading() {
        // Start loading sequence
        for (let step of this.loadingSteps) {
            this.updateProgress(step.progress, step.text);
            await this.waitForAnimation(200);
        }
    }

    async hide() {
        if (!this.loader) return;

        // Add fade out animation
        this.loader.classList.add('fade-out');

        // Wait for animation to complete
        await this.waitForAnimation(500);

        // Remove loader after animation
        this.loader.style.display = 'none';
        this.loader.remove();
    }

    waitForAnimation(duration) {
        return new Promise(resolve => setTimeout(resolve, duration));
    }

    async init() {
        // Start simulating progress
        const loadingPromise = this.simulateLoading();

        // Wait for fonts to load
        const fontsPromise = document.fonts.ready;

        // Run both in parallel
        await fontsPromise;
        await loadingPromise;

        // Hide loader when everything is ready
        await this.hide();
    }
}

// ============================
// Phantom Application Namespace
// ============================
const PhantomApp = {
    pageLoader: null,

    /**
     * Initialize the entire Phantom application
     */
    async initPhantom() {
        try {
            // Initialize page loader
            this.pageLoader = new PhantomPageLoader();
            const loaderPromise = this.pageLoader.init();

            // Initialize components
            this.initPhantomSlider();
            this.initPhantomCopyHandler();

            // Wait for loader to complete
            await loaderPromise;

            console.log('Phantom application initialized successfully');
        } catch (error) {
            console.error('Error initializing Phantom application:', error);
            // Hide loader even if error occurs
            if (this.pageLoader) {
                await this.pageLoader.hide();
            }
        }
    },

    /**
     * Initialize the Phantom feature slider
     * Reads pre-rendered slides from HTML
     */
    initPhantomSlider() {
        const sliderContainer = document.getElementById('sliderContainer');
        const sliderControls = document.getElementById('sliderControls');

        if (sliderContainer && sliderControls) {
            new PhantomFeatureSlider(sliderContainer, sliderControls);
        }
    },

    /**
     * Initialize the Phantom copy button handler
     */
    initPhantomCopyHandler() {
        const copyBtn = document.getElementById('copyBtn');
        const installCommand = document.querySelector('.install-command');

        if (copyBtn && installCommand) {
            new PhantomCopyHandler(copyBtn, installCommand);
        }
    }
};

// ============================
// Phantom Feature Slider Class
// ============================
class PhantomFeatureSlider {
    constructor(container, controls) {
        this.container = container;
        this.controls = controls;
        this.currentSlide = 0;
        this.autoSlideInterval = null;
        this.touchStartX = 0;
        this.touchEndX = 0;
        this.slideDelay = 10000; // 10 seconds

        // Read existing slides from DOM
        this.slides = this.container.querySelectorAll('.feature-slide');
        this.slideCount = this.slides.length;

        if (this.slideCount > 0) {
            this.initPhantomSlider();
        } else {
            console.warn('No feature slides found in the HTML');
        }
    }

    initPhantomSlider() {
        this.createPhantomDots();
        this.attachPhantomEventListeners();
        this.startPhantomAutoSlide();
    }

    createPhantomDots() {
        // Generate dots based on the number of existing slides
        this.controls.innerHTML = Array.from({ length: this.slideCount }, (_, index) =>
            `<span class="slider-dot ${index === 0 ? 'active' : ''}" data-slide="${index}"></span>`
        ).join('');

        this.dots = this.controls.querySelectorAll('.slider-dot');
    }

    goToPhantomSlide(slideIndex) {
        this.currentSlide = slideIndex;
        const offset = -slideIndex * 100;
        this.container.style.transform = `translateX(${offset}%)`;

        this.dots.forEach((dot, index) => {
            dot.classList.toggle('active', index === slideIndex);
        });
    }

    nextPhantomSlide() {
        this.currentSlide = (this.currentSlide + 1) % this.slideCount;
        this.goToPhantomSlide(this.currentSlide);
    }

    prevPhantomSlide() {
        this.currentSlide = (this.currentSlide - 1 + this.slideCount) % this.slideCount;
        this.goToPhantomSlide(this.currentSlide);
    }

    startPhantomAutoSlide() {
        this.autoSlideInterval = setInterval(() => this.nextPhantomSlide(), this.slideDelay);
    }

    stopPhantomAutoSlide() {
        clearInterval(this.autoSlideInterval);
    }

    handlePhantomSwipe() {
        const swipeThreshold = 50;

        if (this.touchEndX < this.touchStartX - swipeThreshold) {
            this.nextPhantomSlide();
        }

        if (this.touchEndX > this.touchStartX + swipeThreshold) {
            this.prevPhantomSlide();
        }
    }

    attachPhantomEventListeners() {
        // Dot click events
        this.dots.forEach((dot, index) => {
            dot.addEventListener('click', () => {
                this.stopPhantomAutoSlide();
                this.goToPhantomSlide(index);
                this.startPhantomAutoSlide();
            });
        });

        // Touch events for mobile swipe
        this.container.addEventListener('touchstart', (e) => {
            this.touchStartX = e.changedTouches[0].screenX;
            this.stopPhantomAutoSlide();
        }, { passive: true });

        this.container.addEventListener('touchend', (e) => {
            this.touchEndX = e.changedTouches[0].screenX;
            this.handlePhantomSwipe();
            this.startPhantomAutoSlide();
        }, { passive: true });

        // Pause on hover
        const sliderElement = this.container.parentElement;
        sliderElement.addEventListener('mouseenter', () => this.stopPhantomAutoSlide());
        sliderElement.addEventListener('mouseleave', () => this.startPhantomAutoSlide());
    }
}

// ============================
// Phantom Copy Handler Class
// ============================
class PhantomCopyHandler {
    constructor(button, command) {
        this.button = button;
        this.command = command;
        this.feedbackDuration = 2000; // 2 seconds
        this.feedbackTimeout = null;

        this.initPhantomCopyHandler();
    }

    initPhantomCopyHandler() {
        this.button.addEventListener('click', () => this.copyPhantomCommand());
        this.attachPhantomHoverEffects();
    }

    waitForAnimation(duration) {
        return new Promise(resolve => setTimeout(resolve, duration));
    }

    async copyPhantomCommand() {
        try {
            // Check clipboard API availability
            if (!navigator.clipboard || (!window.isSecureContext && location.hostname !== 'localhost')) {
                // Use fallback method
                this.phantomFallbackCopy();
                await this.showPhantomSuccess();
                return;
            }

            await navigator.clipboard.writeText(this.command.textContent);
            await this.showPhantomSuccess();
        } catch (err) {
            console.error('Phantom copy failed:', err);
            await this.showPhantomError();
            this.phantomFallbackCopy();
        }
    }

    async showPhantomSuccess() {
        // Cancel any existing feedback timeout
        if (this.feedbackTimeout) {
            clearTimeout(this.feedbackTimeout);
        }

        this.button.classList.add('copied');
        this.button.innerHTML = '<svg class="phantom-icon"><use href="assets/icons/sprite.svg#icon-check"></use></svg>';

        // Use async wait instead of setTimeout
        await this.waitForAnimation(this.feedbackDuration);

        this.button.classList.remove('copied');
        this.button.innerHTML = '<svg class="phantom-icon"><use href="assets/icons/sprite.svg#icon-copy"></use></svg>';
    }

    async showPhantomError() {
        // Cancel any existing feedback timeout
        if (this.feedbackTimeout) {
            clearTimeout(this.feedbackTimeout);
        }

        this.button.classList.add('error');
        this.button.style.animation = 'shake 0.5s';
        this.button.innerHTML = '<svg class="phantom-icon"><use href="assets/icons/sprite.svg#icon-times"></use></svg>';

        // Use async wait instead of setTimeout
        await this.waitForAnimation(this.feedbackDuration);

        this.button.classList.remove('error');
        this.button.style.animation = '';
        this.button.innerHTML = '<svg class="phantom-icon"><use href="assets/icons/sprite.svg#icon-copy"></use></svg>';
    }

    phantomFallbackCopy() {
        const range = document.createRange();
        const selection = window.getSelection();
        range.selectNodeContents(this.command);
        selection.removeAllRanges();
        selection.addRange(range);
    }

    attachPhantomHoverEffects() {
        const container = this.button.parentElement;

        container.addEventListener('mouseenter', () => {
            this.button.style.transform = 'translateY(-50%) scale(1.05)';
        });

        container.addEventListener('mouseleave', () => {
            if (!this.button.classList.contains('copied') && !this.button.classList.contains('error')) {
                this.button.style.transform = 'translateY(-50%) scale(1)';
            }
        });

        // Touch support for mobile devices
        let touchTimeout;

        container.addEventListener('touchstart', () => {
            this.button.style.transform = 'translateY(-50%) scale(1.05)';
            clearTimeout(touchTimeout);
        }, { passive: true });

        container.addEventListener('touchend', () => {
            touchTimeout = setTimeout(() => {
                if (!this.button.classList.contains('copied') && !this.button.classList.contains('error')) {
                    this.button.style.transform = 'translateY(-50%) scale(1)';
                }
            }, 100);
        }, { passive: true });
    }
}

// ============================
// Initialize Phantom on DOM Load
// ============================
document.addEventListener('DOMContentLoaded', () => {
    PhantomApp.initPhantom().catch(error => {
        console.error('Failed to initialize Phantom application:', error);
    });
});