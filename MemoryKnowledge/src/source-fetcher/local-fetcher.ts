/**
 * LocalSourceFetcher — clones/syncs from a local `file://` path via simple-git.
 *
 * Use case: index a repo from a read-only local mount (e.g. a central clone
 * bind-mounted into the container) so the container needs ZERO remote credential.
 *
 * Security:
 *   - Only the `file://` scheme is accepted. Real remote URLs stay on
 *     GitSourceFetcher, whose https-only + SSRF blocklist rules are untouched.
 *   - `--no-hardlinks` on clone: git's local-clone optimization can hardlink
 *     into the source `.git/objects`. When the source is a READ-ONLY host mount
 *     we must never hardlink into it, so the clone copies objects instead.
 */

import simpleGit, { CleanOptions, ResetMode } from "simple-git";
import type { ISourceFetcher, FetchResult, SourceType } from "./types.js";

export class LocalSourceFetcher implements ISourceFetcher {
  readonly supportedType: SourceType = "local";

  validate(sourceUrl: string): void {
    if (!sourceUrl.startsWith("file://")) {
      throw new Error(
        `LocalSourceFetcher only supports file:// URLs; got: ${sourceUrl}`,
      );
    }
  }

  async fetch(sourceUrl: string, branch: string, localPath: string): Promise<FetchResult> {
    this.validate(sourceUrl);
    // --no-hardlinks: never hardlink into the (read-only) host git objects.
    await simpleGit().clone(sourceUrl, localPath, [
      "--no-hardlinks",
      "--depth",
      "1",
      "--branch",
      branch,
    ]);
    const version = await this.headCommit(localPath);
    return { localPath, version, sourceType: "local" };
  }

  async sync(sourceUrl: string, branch: string, localPath: string): Promise<FetchResult> {
    this.validate(sourceUrl);
    const git = simpleGit(localPath);
    await git.fetch("origin", branch, { "--depth": 1 });
    await git.reset(ResetMode.HARD, [`origin/${branch}`]);
    // Exclude .codegraph/ from clean, else the codegraph index gets wiped and
    // every incremental sync falls back to a full clone (mirrors GitSourceFetcher).
    await git.clean(CleanOptions.FORCE + CleanOptions.RECURSIVE, ["-e", ".codegraph"]);
    const version = await this.headCommit(localPath);
    return { localPath, version, sourceType: "local" };
  }

  private async headCommit(localPath: string): Promise<string | null> {
    try {
      return (await simpleGit(localPath).revparse(["HEAD"])).trim().slice(0, 12);
    } catch {
      return null;
    }
  }
}
