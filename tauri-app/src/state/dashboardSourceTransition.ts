import type {
  CodexHomeSourceEnvelope,
  CodexHomeSourceToken,
} from "../types/dashboard";

export type DashboardSourceToken = CodexHomeSourceToken;

export interface DashboardSourceTransition {
  sourceToken: DashboardSourceToken | null;
  deferredGeneration: number;
}

export interface DashboardSourceTransitionResult {
  accepted: boolean;
  initialized: boolean;
  sourceChanged: boolean;
  transition: DashboardSourceTransition;
}

export function createDashboardSourceTransition(): DashboardSourceTransition {
  return {
    sourceToken: null,
    deferredGeneration: 0,
  };
}

export function acceptDashboardSourceEnvelope(
  transition: DashboardSourceTransition,
  envelope: CodexHomeSourceEnvelope,
): DashboardSourceTransitionResult {
  const incoming = dashboardSourceTokenFromEnvelope(envelope);
  if (!validSourceToken(incoming)) {
    return rejectedTransition(transition);
  }

  const current = transition.sourceToken;
  if (current === null) {
    return {
      accepted: true,
      initialized: true,
      sourceChanged: false,
      transition: {
        ...transition,
        sourceToken: incoming,
      },
    };
  }

  if (incoming.transitionGeneration < current.transitionGeneration) {
    return rejectedTransition(transition);
  }

  if (incoming.transitionGeneration === current.transitionGeneration) {
    if (
      incoming.canonicalHomeKey !== current.canonicalHomeKey
      || incoming.physicalHomeKey !== current.physicalHomeKey
    ) {
      return rejectedTransition(transition);
    }
    return {
      accepted: true,
      initialized: false,
      sourceChanged: false,
      transition,
    };
  }

  if (
    incoming.canonicalHomeKey === current.canonicalHomeKey
    && incoming.physicalHomeKey === current.physicalHomeKey
  ) {
    // The Rust publisher never advances generation for an unchanged physical source.
    return rejectedTransition(transition);
  }

  return {
    accepted: true,
    initialized: false,
    sourceChanged: true,
    transition: {
      sourceToken: incoming,
      deferredGeneration: transition.deferredGeneration + 1,
    },
  };
}

export function acceptDashboardSourceResponse(
  transition: DashboardSourceTransition,
  envelope: CodexHomeSourceEnvelope | null,
): DashboardSourceTransitionResult {
  return envelope === null
    ? rejectedTransition(transition)
    : acceptDashboardSourceEnvelope(transition, envelope);
}

export function captureDashboardSourceToken(
  transition: DashboardSourceTransition,
): DashboardSourceToken {
  if (transition.sourceToken === null) {
    throw new Error("Dashboard source is not initialized");
  }
  return transition.sourceToken;
}

export function dashboardSourceTokenMatches(
  transition: DashboardSourceTransition,
  token: DashboardSourceToken | null,
): boolean {
  const current = transition.sourceToken;
  return current !== null
    && token !== null
    && current.transitionGeneration === token.transitionGeneration
    && current.canonicalHomeKey === token.canonicalHomeKey
    && current.physicalHomeKey === token.physicalHomeKey;
}

export function publishForDashboardSource(
  transition: DashboardSourceTransition,
  token: DashboardSourceToken | null,
  publish: () => void,
): boolean {
  if (!dashboardSourceTokenMatches(transition, token)) {
    return false;
  }
  publish();
  return true;
}

export function dashboardSourceTokenFromEnvelope(
  envelope: CodexHomeSourceEnvelope,
): DashboardSourceToken {
  return {
    canonicalHomeKey: envelope.canonicalHomeKey,
    physicalHomeKey: envelope.physicalHomeKey,
    transitionGeneration: envelope.transitionGeneration,
  };
}

function validSourceToken(token: DashboardSourceToken): boolean {
  return token.canonicalHomeKey.trim().length > 0
    && token.physicalHomeKey.trim().length > 0
    && Number.isSafeInteger(token.transitionGeneration)
    && token.transitionGeneration > 0;
}

function rejectedTransition(
  transition: DashboardSourceTransition,
): DashboardSourceTransitionResult {
  return {
    accepted: false,
    initialized: false,
    sourceChanged: false,
    transition,
  };
}
