# Independent review of Swift private parser jobs

Reviewed source commit: `a53dc64c8b3fc7eed2c6d2308be36032dbde7632`.

This is a source review against its parent, not native runtime evidence. The
reviewer did not execute Swift on the Linux workspace. The required native
Swift CI and the source-count scale matrix must pass on the final integrated
commit before this change is treated as validated.

## Findings

### Retained A-only jobs can be missed after a directory alias changes

This is an inherited compatibility gap at the boundary reused by the change,
not a demonstrated new failure introduced by private staging.

`BusinessSQLiteRoutes.store(for:)` resolves a store by stable module/source
identity when its persisted logical path uses a different directory alias.
However, `BusinessSQLiteRoutes.allStores(in:)` filters catalog paths with a
literal path prefix, and `BusinessStoreFiles.stageURLs(in:)` additionally
compares the parent directory literally. `discoverStagingInventory()` supplies
directories derived from the index driver's URL. Therefore a retained stage
that exists only in A, whose catalog uses an alias spelling, can be absent from
the inventory when the index is opened using the physical spelling. There is
no physical stage file for directory enumeration to find instead.

The existing physical-stage migration test retains the original physical
stage and uses one directory spelling. The existing directory-alias test
exercises quota history, not parser-stage discovery. A meaningful regression
case must migrate a complete legacy stage using an aliased Exact root, remove
its obsolete physical copy while retaining the verified A partition, restart
with the physical root spelling, and require reuse without invoking the
parser. The published ledger and retained evidence must remain unchanged if
the recovery proof fails.

This finding was sent to the Swift implementation owner and integration owner
for repair and native regression coverage.

## Reviewed invariants

| Boundary | Source-review result | Remaining validation |
| --- | --- | --- |
| Missing or empty legacy migration header | The new early equality guard does not narrow successful reuse: the preexisting full-row validator already required the exact migration revision. An unclassifiable artifact remains retained; it is not deleted. | Existing legacy-format native tests plus an explicit malformed-header negative case if the classification code changes. |
| Known opposite-purpose complete stage | The new branch validates the entire stage using its original purpose before preserving it aside. Unknown future revisions continue to throw. Damaged stages do not become permission to rebuild. | Native checkpoint-reset positive and corrupt-stage negative tests added by the implementation. |
| Cached candidate inventory | The inventory is created under the index operation gate, only read by parser workers, and cleared after all workers have joined. The primary path is checked separately on every lookup, so newly completed stages are visible on publication retry. | Full 4,124-source run and interrupted-publication restart test. |
| Private-stage routing | `staging-private-v1/` is excluded by the configuration's explicit relative-path matching, before and after the directory exists. A normal stage cannot become an A partition simply because its parent was created. | Native test asserts both configuration lookup and active route lookup are nil. |
| Publication failure | Parsing happens outside the tentative A publication transaction; the complete generation commits before cleanup. Import failure rolls back the new generation while retaining the complete private jobs. | Added native failure-after-first-import test followed by a fresh migration/startup and a parser-forbidden resume. |
| Existing symlink input | Startup discovery rejects symlink descendants before collecting legacy inputs, including descendants of the new private-stage directory. Configured root aliases remain intentionally supported. | A change to private-stage filesystem ownership should add explicit leaf/directory replacement tests; this review does not claim protection against every post-startup external mutation. |

## Coverage limits

The added native test uses genuine migration and production index methods but
synthetic small rollouts. It does not itself prove the complete native Swift
v0.9.8–v0.9.11 formed-release chain. The formed-release workflow currently
compiles the Rust runtime on both Windows and macOS; its macOS result must not
be described as native Swift formed-release coverage. The scale probe uses one
event per source and measures schema growth, progress, and publication cost;
it does not substitute for large byte-volume or installed-application UX
acceptance.
