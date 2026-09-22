// @vitest-environment jsdom

import { act, createElement } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  shouldShowSubtitleNavigation,
  SubtitleNavigationControls,
} from '@/components/roundtable/subtitle-navigation';

describe('roundtable subtitle navigation', () => {
  let container: HTMLDivElement;
  let root: Root;

  beforeEach(() => {
    vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
    container = document.createElement('div');
    document.body.appendChild(container);
    root = createRoot(container);
  });

  afterEach(() => {
    act(() => root.unmount());
    container.remove();
    vi.unstubAllGlobals();
  });

  it('is limited to stopped teacher lecture phases with multiple subtitles', () => {
    expect(shouldShowSubtitleNavigation('teacher', 'idle', 2)).toBe(true);
    expect(shouldShowSubtitleNavigation('teacher', 'lecturePaused', 2)).toBe(true);
    expect(shouldShowSubtitleNavigation('teacher', 'completed', 2)).toBe(true);

    expect(shouldShowSubtitleNavigation('teacher', 'lecturePlaying', 2)).toBe(false);
    expect(shouldShowSubtitleNavigation('teacher', 'discussionActive', 2)).toBe(false);
    expect(shouldShowSubtitleNavigation('agent', 'lecturePaused', 2)).toBe(false);
    expect(shouldShowSubtitleNavigation('user', 'lecturePaused', 2)).toBe(false);
    expect(shouldShowSubtitleNavigation('teacher', 'lecturePaused', 1)).toBe(false);
  });

  it('disables unavailable directions and stops bubble click propagation', () => {
    const onPrevious = vi.fn();
    const onNext = vi.fn();
    const onBubbleClick = vi.fn();

    act(() => {
      root.render(
        createElement(
          'div',
          { onClick: onBubbleClick },
          createElement(SubtitleNavigationControls, {
            navigation: {
              currentLine: 1,
              totalLines: 2,
              canGoPrevious: false,
              canGoNext: true,
              onPrevious,
              onNext,
            },
            previousLabel: 'Previous subtitle',
            nextLabel: 'Next subtitle',
            progressLabel: 'Subtitle 1 of 2',
          }),
        ),
      );
    });

    const buttons = container.querySelectorAll('button');
    expect(buttons).toHaveLength(2);
    expect(buttons[0].disabled).toBe(true);
    expect(buttons[1].disabled).toBe(false);
    expect(buttons[1].getAttribute('aria-label')).toBe('Next subtitle · Subtitle 1 of 2');

    act(() => {
      buttons[0].dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
      buttons[1].dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    });

    expect(onPrevious).not.toHaveBeenCalled();
    expect(onNext).toHaveBeenCalledOnce();
    expect(onBubbleClick).not.toHaveBeenCalled();
  });
});
