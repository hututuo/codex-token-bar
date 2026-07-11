export type UpdatePublicationOwner = "automatic" | "manual";

export interface UpdatePublicationToken {
  readonly generation: number;
  readonly owner: UpdatePublicationOwner;
}

export interface UpdatePublicationGate {
  beginAutomatic: () => UpdatePublicationToken | null;
  beginManual: () => UpdatePublicationToken | null;
  finish: (token: UpdatePublicationToken) => void;
  isCurrent: (token: UpdatePublicationToken) => boolean;
  settle: (token: UpdatePublicationToken) => boolean;
}

export function createUpdatePublicationGate(): UpdatePublicationGate {
  let generation = 0;
  let current: UpdatePublicationToken | null = null;

  const begin = (owner: UpdatePublicationOwner): UpdatePublicationToken => {
    generation += 1;
    current = Object.freeze({ generation, owner });
    return current;
  };

  const isCurrent = (token: UpdatePublicationToken) => (
    current?.generation === token.generation && current.owner === token.owner
  );

  const settle = (token: UpdatePublicationToken) => {
    if (!isCurrent(token)) {
      return false;
    }
    current = null;
    return true;
  };

  return {
    beginAutomatic: () => {
      if (current?.owner === "manual") {
        return null;
      }
      return current ?? begin("automatic");
    },
    beginManual: () => current?.owner === "manual" ? null : begin("manual"),
    finish: (token) => {
      settle(token);
    },
    isCurrent,
    settle,
  };
}
