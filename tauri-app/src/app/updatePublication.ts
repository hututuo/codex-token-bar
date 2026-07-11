export type UpdatePublicationOwner = "automatic" | "manual";

export interface UpdatePublicationToken {
  readonly generation: number;
  readonly owner: UpdatePublicationOwner;
}

export interface UpdatePublicationSubscriber {
  readonly token: UpdatePublicationToken;
  cancel: () => void;
  settle: () => boolean;
}

export interface UpdatePublicationGate {
  beginManual: () => UpdatePublicationToken | null;
  finish: (token: UpdatePublicationToken) => void;
  isCurrent: (token: UpdatePublicationToken) => boolean;
  subscribeAutomatic: () => UpdatePublicationSubscriber | null;
}

export function createUpdatePublicationGate(): UpdatePublicationGate {
  let generation = 0;
  let subscriberId = 0;
  let current: {
    automaticSubscribers: Set<number>;
    token: UpdatePublicationToken;
  } | null = null;

  const begin = (owner: UpdatePublicationOwner): UpdatePublicationToken => {
    generation += 1;
    const token = Object.freeze({ generation, owner });
    current = { automaticSubscribers: new Set(), token };
    return token;
  };

  const isCurrent = (token: UpdatePublicationToken) => (
    current?.token.generation === token.generation && current.token.owner === token.owner
  );

  const finish = (token: UpdatePublicationToken) => {
    if (!isCurrent(token)) {
      return false;
    }
    current = null;
    return true;
  };

  return {
    beginManual: () => current?.token.owner === "manual" ? null : begin("manual"),
    finish: (token) => {
      finish(token);
    },
    isCurrent,
    subscribeAutomatic: () => {
      if (current?.token.owner === "manual") {
        return null;
      }
      const token = current?.token ?? begin("automatic");
      const id = ++subscriberId;
      current?.automaticSubscribers.add(id);
      let active = true;
      return {
        token,
        cancel: () => {
          if (!active) {
            return;
          }
          active = false;
          if (!isCurrent(token) || current?.token.owner !== "automatic") {
            return;
          }
          current.automaticSubscribers.delete(id);
        },
        settle: () => {
          if (!active) {
            if (
              isCurrent(token)
              && current?.token.owner === "automatic"
              && current.automaticSubscribers.size === 0
            ) {
              current = null;
            }
            return false;
          }
          active = false;
          if (
            !isCurrent(token)
            || current?.token.owner !== "automatic"
            || !current.automaticSubscribers.delete(id)
          ) {
            return false;
          }
          current = null;
          return true;
        },
      };
    },
  };
}
