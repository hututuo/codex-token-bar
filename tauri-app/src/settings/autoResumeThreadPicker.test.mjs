import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("auto resume picker groups by project and keeps at least the latest fifty titles", async () => {
  await withSsrModules(async (load) => {
    const {
      AUTO_RESUME_VISIBLE_THREAD_LIMIT,
      autoResumeProjectKey,
      autoResumeThreadsInProject,
      buildAutoResumeProjects,
      visibleAutoResumeThreads,
    } = await load("/src/settings/autoResumeThreadPicker.ts");
    const mainThreads = Array.from({ length: 125 }, (_, index) => ({
      id: `main-${index}`,
      title: `完整会话标题 ${index}`,
      cwd: "/Users/test/main-project",
      updatedAt: 10_000 - index,
      status: "idle",
      source: "state-db",
    }));
    const threads = [
      ...mainThreads,
      {
        id: "other-1",
        title: "另一个项目",
        cwd: "/Users/test/other-project",
        updatedAt: 20_000,
        status: "active",
        source: "state-db",
      },
    ];

    const projects = buildAutoResumeProjects(threads);
    assert.equal(projects.length, 2);
    assert.equal(projects[0].cwd, "/Users/test/other-project", "projects sort by latest activity");
    assert.equal(projects[1].threadCount, 125);

    const mainKey = autoResumeProjectKey("/Users/test/main-project/");
    assert.equal(autoResumeThreadsInProject(threads, mainKey).length, 125, "same-project threads are not deduplicated");
    const visible = visibleAutoResumeThreads(threads, mainKey, "");
    assert.equal(AUTO_RESUME_VISIBLE_THREAD_LIMIT, 100);
    assert.equal(visible.length, 100);
    assert.deepEqual(visible.slice(0, 3).map((thread) => thread.title), [
      "完整会话标题 0",
      "完整会话标题 1",
      "完整会话标题 2",
    ]);
  });
});

test("auto resume picker searches the whole selected project before applying its display limit", async () => {
  await withSsrModules(async (load) => {
    const { autoResumeProjectKey, visibleAutoResumeThreads } = await load(
      "/src/settings/autoResumeThreadPicker.ts",
    );
    const cwd = "/Users/test/project";
    const threads = Array.from({ length: 130 }, (_, index) => ({
      id: `thread-${index}`,
      title: index === 125 ? "只在旧会话里的针" : `普通会话 ${index}`,
      cwd,
      updatedAt: 1_000 - index,
      status: "idle",
      source: "state-db",
    }));

    const result = visibleAutoResumeThreads(threads, autoResumeProjectKey(cwd), "针");
    assert.deepEqual(result.map((thread) => thread.id), ["thread-125"]);

    const withOldSelection = visibleAutoResumeThreads(
      threads,
      autoResumeProjectKey(cwd),
      "",
      "thread-125",
    );
    assert.equal(withOldSelection.length, 100);
    assert.equal(withOldSelection.at(-1)?.id, "thread-125", "saved selection stays available beyond the recent window");
  });
});
