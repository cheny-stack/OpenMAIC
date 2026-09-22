import { ChevronDown, ChevronUp } from 'lucide-react';
import type { PlaybackPhase } from '@/lib/playback';
import { cn } from '@/lib/utils';

export interface SubtitleNavigationModel {
  currentLine: number;
  totalLines: number;
  canGoPrevious: boolean;
  canGoNext: boolean;
  onPrevious: () => void;
  onNext: () => void;
}

interface SubtitleNavigationControlsProps {
  readonly navigation: SubtitleNavigationModel;
  readonly previousLabel: string;
  readonly nextLabel: string;
  readonly progressLabel: string;
}

export function shouldShowSubtitleNavigation(
  bubbleRole: 'teacher' | 'agent' | 'user' | null,
  phase: PlaybackPhase | undefined,
  totalLines: number,
): boolean {
  return (
    bubbleRole === 'teacher' &&
    totalLines > 1 &&
    (phase === 'idle' || phase === 'lecturePaused' || phase === 'completed')
  );
}

export function SubtitleNavigationControls({
  navigation,
  previousLabel,
  nextLabel,
  progressLabel,
}: SubtitleNavigationControlsProps) {
  const buttons = [
    {
      key: 'previous',
      label: previousLabel,
      enabled: navigation.canGoPrevious,
      onClick: navigation.onPrevious,
      Icon: ChevronUp,
    },
    {
      key: 'next',
      label: nextLabel,
      enabled: navigation.canGoNext,
      onClick: navigation.onNext,
      Icon: ChevronDown,
    },
  ] as const;

  return (
    <div
      className="absolute right-2.5 bottom-10 z-20 flex flex-col gap-0.5"
      onClick={(event) => event.stopPropagation()}
    >
      {buttons.map(({ key, label, enabled, onClick, Icon }) => {
        const accessibleLabel = `${label} · ${progressLabel}`;
        return (
          <button
            key={key}
            type="button"
            disabled={!enabled}
            title={accessibleLabel}
            aria-label={accessibleLabel}
            onClick={(event) => {
              event.stopPropagation();
              if (enabled) onClick();
            }}
            className={cn(
              'flex h-6 w-6 items-center justify-center rounded-full border transition-colors',
              enabled
                ? 'cursor-pointer border-gray-200/70 bg-gray-50/90 text-gray-400 hover:border-purple-200 hover:bg-purple-100 hover:text-purple-600 dark:border-gray-600/70 dark:bg-gray-700/90 dark:text-gray-400 dark:hover:border-purple-700 dark:hover:bg-purple-900/50 dark:hover:text-purple-400'
                : 'cursor-not-allowed border-gray-100/60 bg-gray-50/50 text-gray-300 opacity-50 dark:border-gray-700/60 dark:bg-gray-800/50 dark:text-gray-600',
            )}
          >
            <Icon className="h-3.5 w-3.5" aria-hidden="true" />
          </button>
        );
      })}
    </div>
  );
}
