import type { UpdateAvailability } from "../api/updateClient";
import type {
  UpdatePublicationGate,
  UpdatePublicationToken,
} from "./updatePublication";

type AvailableUpdate = Extract<UpdateAvailability, { status: "available" }>;

export type UpdateInstallationState =
  | { kind: "idle"; message: string; update: null }
  | { kind: "installing"; message: string; update: AvailableUpdate }
  | { kind: "error"; message: string; update: null };

interface InstallPendingUpdateOptions {
  install: (
    update: AvailableUpdate["update"],
    onProgress?: (message: string) => void,
  ) => Promise<void>;
  publication: UpdatePublicationGate;
  publish: (state: UpdateInstallationState) => void;
  token: UpdatePublicationToken;
  update: AvailableUpdate;
}

export async function installPendingUpdate({
  install,
  publication,
  publish,
  token,
  update,
}: InstallPendingUpdateOptions) {
  try {
    if (!publication.isCurrent(token)) {
      return;
    }
    publish({
      kind: "installing",
      message: "正在下载更新...",
      update,
    });
    await install(update.update, (message) => {
      if (!publication.isCurrent(token)) {
        return;
      }
      publish({ kind: "installing", message, update });
    });
    if (!publication.isCurrent(token)) {
      return;
    }
    publish({
      kind: "idle",
      message: "更新已安装，请重新启动应用",
      update: null,
    });
  } catch {
    if (!publication.isCurrent(token)) {
      return;
    }
    publish({
      kind: "error",
      message: "更新未完成，请稍后重试",
      update: null,
    });
  } finally {
    publication.finish(token);
  }
}
