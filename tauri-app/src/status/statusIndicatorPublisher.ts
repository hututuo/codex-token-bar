import type { StatusIndicatorPresentation } from "./statusIndicatorPresentation";

type StatusIndicatorReadout = Pick<
  StatusIndicatorPresentation,
  "title" | "tooltip" | "width"
>;

export interface StatusIndicatorPublishAttempt {
  committedSignature: string;
  published: boolean;
  shouldRetry: boolean;
}

export async function attemptStatusIndicatorReadoutPublish(
  readout: StatusIndicatorReadout,
  committedSignature: string,
  publish: (title: string, tooltip: string, width: number) => Promise<boolean>,
): Promise<StatusIndicatorPublishAttempt> {
  const nextSignature = statusIndicatorReadoutSignature(readout);
  if (nextSignature === committedSignature) {
    return {
      committedSignature,
      published: false,
      shouldRetry: false,
    };
  }

  try {
    const succeeded = await publish(readout.title, readout.tooltip, readout.width);
    return succeeded
      ? {
          committedSignature: nextSignature,
          published: true,
          shouldRetry: false,
        }
      : {
          committedSignature,
          published: false,
          shouldRetry: true,
        };
  } catch {
    return {
      committedSignature,
      published: false,
      shouldRetry: true,
    };
  }
}

export function statusIndicatorReadoutSignature(
  readout: StatusIndicatorReadout,
): string {
  return JSON.stringify([readout.title, readout.tooltip, readout.width]);
}
