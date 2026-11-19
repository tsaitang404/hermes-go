import 'package:dsh_app/update/update_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the fork release selects only the fork GitHub feed, API and assets', () {
    const repo = String.fromEnvironment('DSH_UPDATE_REPO');
    if (repo.isEmpty) {
      // The rest of the update tests exercise the standard upstream build.
      expect(updateRepo, 'ccch1mneyyy/dsh-go');
      return;
    }
    expect(repo, 'tsaitang404/hermes-go');
    final sources = defaultUpdateSources();
    expect(sources.channel, isNull);
    expect(sources.feed, isNull);
    expect(sources.mirrors.map((m) => m.id), ['github']);
    expect(sources.metadataEndpoints().map((endpoint) => endpoint.url.toString()), [
      'https://github.com/$repo/releases/latest/download/update.json',
      'https://api.github.com/repos/$repo/releases/latest',
    ]);
    final asset = githubReleaseAsset('v1.2.0', 'dsh-go-1.2.0-arm64.apk');
    expect(sources.downloadUrls([asset]).map((source) => source.url.toString()), [
      'https://github.com/$repo/releases/download/v1.2.0/dsh-go-1.2.0-arm64.apk',
    ]);
  });
}
