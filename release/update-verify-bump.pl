#!/usr/bin/perl -w
use strict;

use File::Path;
use File::Spec::Functions;
use File::Temp qw(tempdir);
use Getopt::Long;

use MozBuild::Util qw(GetBuildIDFromFTP);
use Bootstrap::Util qw(LoadLocaleManifest);

$|++;

my %config;

ProcessArgs();
if (defined $config{'run-tests'}) {
    RunUnitTests();
} else {
    BumpVerifyConfig();
}

sub ProcessArgs {
	GetOptions(
		\%config,
        "osname|o=s", "product|p=s", "brand|r=s", "old-version=s", "old-app-version=s",
        "old-long-version=s", "version|v=s", "app-version=s", "long-version=s",
        "build-number|n=s", "aus-server-url|a=s", "staging-server|s=s",
        "verify-config|c=s", "old-candidates-dir|d=s", "linux-extension|e=s",
        "shipped-locales|l=s", "pretty-candidates-dir", "major|m",
        "help", "run-tests"
    );

    if ($config{'help'}) {
        print <<__USAGE__;
Usage: update-verify-bump.pl [options]
This script depends on the MozBuild::Util and Bootstrap::Util modules.
Options requiring arguments:
  --osname/-o             One of (linux, macosx, win32).
  --product/-p            The product name (eg. firefox, thunderbird, seamonkey, etc.).
  --brand/-r              The brand name (eg. Firefox, Thunderbird, SeaMonkey, etc.)
                          If not specified, a first-letter-uppercased product name is assumed.
  --old-version           The previous version of the product.
  --old-app-version       The previous 'app version of the product'.
                          If not passed, is assumed to be the same as
                          --old-version.
  --old-long-version      The previous long version of the product.
                          Eg. '3.1 Beta 1'. If not passed, is assumed to be the
                          same as --old-version.
  --version/-v            The current version of the product. Eg. 3.0.3, 3.1b1,
                          3.1rc2.
  --app-version           The current app version of the product. If not passed,
                          is assumed to be the same as --version. Usually the
                          same as version except for RC releases. Eg, when
                          version is 3.1rc2, appVersion is 3.1.
  --long-version          The current long version of the product. Only
                          necessary when --pretty-candidates-dir is passed and
                          is different than --version.
  --build-number/-n       The current build number of the product.
  --aus-server-url/-a     The URL to be used when constructing update URLs.
                          Eg. https://aus2.mozilla.org
  --staging-server/-s     The staging server that builds should be pulled from.
  --verify-config/-c      The path and filename of the config file to be bumped.
  --old-candidates-dir/-d The path (on the staging server) to the candidates
                          directory for the previous release.
                          Eg. /home/ftp/pub/firefox/nightly/3.1b1-candidates/build1
  --linux-extension/-e    The extension to use for Linux packages. Assumed to
                          be bz2 if not passed.
  --shipped-locales/-l    The path and filename to the shipped-locales file
                          for this release.
Options without arguments:
  --pretty-candidates-dir When passed, the "to" field in the verify config will
                          be formatted the "pretty" way by using the long
                          version number on mac and win32, and storing files
                          in a deep directory format rather than encoding all
                          of the information into the filename. This flag does
                          not take an argument.
  --major/-m              Major update (MU) mode, which starts the file from
                          scratch rather than appending
  --help                  This usage message. This flag takes no arguments.
  --run-tests             Run the (very basic) unit tests include with this
                          script. This flag takes no arguments.
__USAGE__

        exit(0);
    }

    my $error = 0;

    # Input validation. Not necessary if we're running tests.
    if (! defined $config{'run-tests'}) {
        for my $arg ('osname', 'product', 'old-version',
                     'version', 'build-number', 'aus-server-url',
                     'staging-server', 'old-candidates-dir') {
            if (! defined $config{$arg}) {
                print "$arg must be defined.\n";
                $error = 1;
            }
        }
        if (! defined $config{'verify-config'} or
                 ! -w $config{'verify-config'}) {
            print "verify config file must exist and be writable.\n";
            $error = 1;
        }
        if (! defined $config{'shipped-locales'} or
                 ! -e $config{'shipped-locales'}) {
            print "shipped locales file must exist.\n";
            $error = 1;
        }
        if (defined $config{'pretty-candidates-dir'} and
               ! defined $config{'long-version'}) {
            print "long-version must be defined when passing " .
                  "--pretty-candidates-dir";
            $error = 1;
        } 
        if ($error) {
            exit($error);
        }

        # set sane defaults
        if (! defined $config{'brand'}) {
            $config{'brand'} = ucfirst($config{'product'});
        }
        if (! defined $config{'old-app-version'}) {
            $config{'old-app-version'} = $config{'old-version'};
        }
        if (! defined $config{'old-long-version'}) {
            $config{'old-long-version'} = $config{'old-version'};
        }
        if (! defined $config{'app-version'}) {
            $config{'app-version'} = $config{'version'};
        }
        if (! defined $config{'long-version'}) {
            $config{'long-version'} = $config{'version'};
        }
        if (! defined $config{'linux-extension'}) {
            $config{'linux-extension'} = 'bz2';
        }
        if (! defined $config{'pretty-candidates-dir'}) {
            $config{'pretty-candidates-dir'} = 0;
        }
        if (! defined $config{'major'}) {
            $config{'major'} = 0;
        }
    }
}

sub BumpVerifyConfig {
    my $this = shift;

    my $osname = $config{'osname'};
    my $product = $config{'product'};
    my $brand = $config{'brand'};
    my $oldVersion = $config{'old-version'};
    my $oldAppVersion = $config{'old-app-version'};
    my $oldLongVersion = $config{'old-long-version'};
    my $version = $config{'version'};
    my $appVersion = $config{'app-version'};
    my $longVersion = $config{'long-version'};
    my $build = $config{'build-number'};
    my $ausServerUrl = $config{'aus-server-url'};
    my $stagingServer = $config{'staging-server'};
    my $configFile = $config{'verify-config'};
    my $candidatesDir = $config{'old-candidates-dir'};
    my $linuxExtension = $config{'linux-extension'};
    my $shippedLocales = $config{'shipped-locales'};
    my $prettyCandidatesDir = $config{'pretty-candidates-dir'};
    my $majorMode = $config{'major'};

    # NOTE - channel is hardcoded to betatest
    my $channel = 'betatest';

    my $buildID = GetBuildIDFromFTP(os => $osname,
                                    releaseDir => $candidatesDir,
                                    stagingServer => $stagingServer);

    my $buildTarget = undef;
    my $platform = undef;
    my $releaseFile = undef;
    my $nightlyFile = undef;
    my $ftpOsname = undef;

    if ($osname eq 'linux') {
        $buildTarget = 'Linux_x86-gcc3';
        $platform = 'linux';
        $ftpOsname = 'linux-i686';
        $releaseFile = $product.'-'.$oldVersion.'.tar.'.$linuxExtension;
        if ($prettyCandidatesDir) {
            $nightlyFile = 'linux-i686/%locale%/'.$product.'-'.$version.
             '.tar.'.$linuxExtension;
        } else {
            $nightlyFile = $product.'-'.$appVersion.'.%locale%.linux-i686.tar.'.
             $linuxExtension;
        }
    } elsif ($osname eq 'macosx') {
        $buildTarget = 'Darwin_Universal-gcc3';
        $platform = 'osx';
        $ftpOsname = 'mac';
        $releaseFile = $brand.' '.$oldLongVersion.'.dmg';
        if ($prettyCandidatesDir) {
            $nightlyFile = 'mac/%locale%/'.$brand.' '.$longVersion.
             '.dmg';
        } else {
            $nightlyFile = $product.'-'.$appVersion.'.%locale%.mac.dmg';
        }
    } elsif ($osname eq 'win32') {
        $buildTarget = 'WINNT_x86-msvc';
        $platform = 'win32';
        $ftpOsname = 'win32';
        $releaseFile = $brand.' Setup '.$oldLongVersion.'.exe';
        if ($prettyCandidatesDir) {
            $nightlyFile = 'win32/%locale%/'.$brand. ' Setup '.
             $longVersion.'.exe';
        } else {
            $nightlyFile = $product.'-'.$appVersion.
             '.%locale%.win32.installer.exe';
        }
    } else {
        die("ASSERT: unknown OS $osname");
    }

    open(FILE, "< $configFile") or die ("Could not open file $configFile: $!");
    my @origFile = <FILE>;
    close(FILE) or die ("Could not close file $configFile: $!");

    my @strippedFile = ();
    if ($origFile[0] =~ $oldVersion) {
            print "verifyConfig $configFile already bumped\n";
            print "removing previous config..\n";
            # remove top two lines; the comment and the version config
            splice(@origFile, 0, 2);
            @strippedFile = @origFile;
    } else {
        # remove "from" and "to" vars from @origFile
        for(my $i=0; $i < scalar(@origFile); $i++) {
            my $line = $origFile[$i];
            $line =~ s/from.*$//;
            $strippedFile[$i] = $line;
        }
    }

    my $localeManifest = {};
    if (not LoadLocaleManifest(localeHashRef => $localeManifest,
                               manifest => $shippedLocales)) {
        die "Could not load locale manifest";
    }

    my @locales = ();
    foreach my $locale (keys(%{$localeManifest})) {
        foreach my $allowedPlatform (@{$localeManifest->{$locale}}) {
            if ($allowedPlatform eq $platform) {
                push(@locales, $locale);
            }
        }
    }

    # add data for latest release
    my $from = '/' . $product . '/releases/' . $oldVersion . '/' . $ftpOsname .
        '/%locale%/' . $releaseFile;
    if ( $majorMode ) {
        my $candidatesDirStripped = $candidatesDir;
        $candidatesDirStripped =~ s!/$!!; # Remove trailing slash
        $candidatesDirStripped =~ s!^/.*?/$product/!/$product/!; # Remove FTP prefix
        $from = $candidatesDirStripped . '/' . $ftpOsname . '/%locale%/' . $releaseFile;
    }
    my @data = ("# $oldVersion $osname\n",
                'release="' . $oldAppVersion . '" product="' . $brand . 
                '" platform="' .$buildTarget . '" build_id="' . $buildID . 
                '" locales="' . join(' ', sort(@locales)) . '" channel="' . 
                $channel . '" from="' . $from .
                '" aus_server="' . $ausServerUrl . '" ftp_server="' .
                $stagingServer . '/pub/mozilla.org" to="/' . 
                $product . '/nightly/' .  $version .  '-candidates/build' . 
                $build . '/' . $nightlyFile . '"' .  "\n");

    open(FILE, "> $configFile") or die ("Could not open file $configFile: $!");
    print FILE @data;
    # write the data for the old releases unless we're doing a major update
    if ( ! $majorMode ) {
        print FILE @strippedFile;
    }
    close(FILE) or die ("Could not close file $configFile: $!");
}

sub RunUnitTests {
    # 3.0.x minor update test
    ExecuteTest(product => 'firefox',
                brand => 'Firefox',
                osname => 'linux',
                platform => 'Linux_x86-gcc3',
                version => '3.0.3',
                longVersion => '3.0.3',
                build => '1',
                oldVersion => '3.0.2',
                oldLongVersion => '3.0.2',
                oldBuildid => '2008091618',
                oldFromBuild => '/firefox/releases/3.0.2/linux-i686/%locale%/firefox-3.0.2.tar.bz2',
                oldToBuild => '/firefox/nightly/3.0.3-candidates/build1/firefox-3.0.3.%locale%.linux-i686.tar.bz2',
                oldOldVersion => '3.0.1',
                oldOldLongVersion => '3.0.1',
                oldOldBuildid => '2008070206',
                oldOldFromBuild => '/firefox/releases/3.0.1/linux-i686/%locale%/firefox-3.0.1.tar.bz2',
                oldOldToBuild => '/firefox/nightly/3.0.2-candidates/build6/firefox-3.0.2.%locale%.linux-i686.tar.bz2',
                ausServer => 'https://aus2.mozilla.org',
                stagingServer => 'build.mozilla.org',
                oldCandidatesDir => '/update-bump-unit-tests/pub/mozilla.org/firefox/nightly/3.0.2-candidates/build6',
                prettyCandidatesDir => '0',
                linuxExtension => 'bz2',
                major => 0,
    );
    # 3.1b minor update test (pretty names)
    ExecuteTest(product => 'firefox',
                brand => 'Firefox',
                osname => 'win32',
                platform => 'WINNT_x86-msvc',
                version => '3.1b2',
                longVersion => '3.1 Beta 2',
                build => '1',
                oldVersion => '3.1b1',
                oldLongVersion => '3.1 Beta 1',
                oldBuildid => '20081007144708',
                oldFromBuild => '/firefox/releases/3.1b1/win32/%locale%/Firefox Setup 3.1 Beta 1.exe',
                oldToBuild => '/firefox/nightly/3.1b2-candidates/build1/win32/%locale%/Firefox Setup 3.1 Beta 2.exe',
                oldOldVersion => '3.1a2',
                oldOldLongVersion => '3.1 Alpha 2',
                oldOldBuildid => '20080829082037',
                oldOldFromBuild => '/firefox/releases/shiretoko/alpha2/win32/en-US/Shiretoko Alpha 2 Setup.exe',
                oldOldToBuild => '/firefox/nightly/3.1b1-candidates/build2/win32/%locale%/Firefox 3.1 Beta 1 Setup.exe',
                ausServer => 'https://aus2.mozilla.org',
                stagingServer => 'build.mozilla.org',
                oldCandidatesDir => '/update-bump-unit-tests/pub/mozilla.org/firefox/nightly/3.1b1-candidates/build2',
                prettyCandidatesDir => '1',
                linuxExtension => 'bz2',
                major => 0,
    );
    # major update test
    ExecuteTest(product => 'firefox',
                brand => 'Firefox',
                osname => 'win32',
                platform => 'WINNT_x86-msvc',
                version => '3.6b4',
                longVersion => '3.6 Beta 4',
                build => '1',
                oldVersion => '3.5.5',
                oldLongVersion => '3.5.5',
                oldBuildid => '20091102152451',
                oldFromBuild => '/firefox/releases/3.5.5/win32/%locale%/Firefox Setup 3.5.5.exe',
                oldToBuild => '/firefox/nightly/3.6b4-candidates/build1/win32/%locale%/Firefox Setup 3.6 Beta 4.exe',
                oldOldVersion => '',
                oldOldLongVersion => '',
                oldOldBuildid => '',
                oldOldFromBuild => '',
                oldOldToBuild => '',
                ausServer => 'https://aus2.mozilla.org',
                stagingServer => 'build.mozilla.org',
                oldCandidatesDir => '/update-bump-unit-tests/pub/mozilla.org/firefox/nightly/3.5.5-candidates/build1',
                prettyCandidatesDir => '1',
                linuxExtension => 'bz2',
                major => 1,
    );
}

sub ExecuteTest {
    my %args = @_;
    my $product = $args{'product'};
    my $brand = $args{'brand'};
    my $osname = $args{'osname'};
    my $platform = $args{'platform'};
    my $version = $args{'version'};
    my $longVersion = $args{'longVersion'};
    my $build = $args{'build'};
    my $oldVersion = $args{'oldVersion'};
    my $oldLongVersion = $args{'oldLongVersion'};
    my $oldBuildid = $args{'oldBuildid'};
    my $oldFromBuild = $args{'oldFromBuild'};
    my $oldToBuild = $args{'oldToBuild'};
    my $oldOldVersion = $args{'oldOldVersion'};
    my $oldOldLongVersion = $args{'oldOldLongVersion'};
    my $oldOldBuildid = $args{'oldOldBuildid'};
    my $oldOldFromBuild = $args{'oldOldFromBuild'};
    my $oldOldToBuild = $args{'oldOldToBuild'};
    my $ausServer = $args{'ausServer'};
    my $stagingServer = $args{'stagingServer'};
    my $oldCandidatesDir = $args{'oldCandidatesDir'};
    my $prettyCandidatesDir = $args{'prettyCandidatesDir'};
    my $linuxExtension = $args{'linuxExtension'};
    my $majorMode = $args{'major'};

    my $workdir = tempdir(CLEANUP => 0);
    my $bumpedConfig = catfile($workdir, 'bumped-update-verify.cfg');
    my $referenceConfig = catfile($workdir, 'reference-update-verify.cfg');
    my $shippedLocales = catfile($workdir, 'shipped-locales');
    my $diffFile = catfile($workdir, 'update-verify.diff');

    print "Running test on: $product, $osname, version $version, majorMode $majorMode.....";

    # Create shipped-locales
    open(SHIPPED_LOCALES, ">$shippedLocales");
    print SHIPPED_LOCALES "af\n";
    print SHIPPED_LOCALES "en-US\n";
    print SHIPPED_LOCALES "gu-IN linux win32\n";
    print SHIPPED_LOCALES "ja linux win32\n";
    print SHIPPED_LOCALES "ja-JP-mac osx\n";
    print SHIPPED_LOCALES "uk\n";
    close(SHIPPED_LOCALES);

    my $localeInfo = {};
    if (not LoadLocaleManifest(localeHashRef => $localeInfo,
                               manifest => $shippedLocales)) {
        die "Could not load locale manifest";
    }

    # Create a verify config to bump
    my @oldOldRelease = (
        "release=\"$oldOldVersion\"",
        "product=\"$brand\"",
        "platform=\"$platform\"",
        "build_id=\"$oldOldBuildid\"",
        "locales=\"af en-US gu-IN ja uk\"",
        "channel=\"betatest\"",
        "from=\"$oldOldFromBuild\"",
        "aus_server=\"$ausServer\"",
        "ftp_server=\"$stagingServer/pub/mozilla.org\"",
        "to=\"$oldOldToBuild\""
    );

    open(CONFIG, ">$bumpedConfig");
    print CONFIG "# $oldOldVersion $osname\n";
    print CONFIG join(' ', @oldOldRelease);
    close(CONFIG);

    # Prepare the reference file...
    # BumpVerifyConfig removes everything after 'from' for the previous release
    # So must we in the reference file.
    @oldOldRelease = (
        "release=\"$oldOldVersion\"",
        "product=\"$brand\"",
        "platform=\"$platform\"",
        "build_id=\"$oldOldBuildid\"",
        "locales=\"af en-US gu-IN ja uk\"",
        "channel=\"betatest\" " # this trailing space is intentional and
                                # necessary because of how BumpVerifyConfig
                                # strips the previous release
    );

    # Now create an already bumped configuration to file
    my @oldRelease = (
        "release=\"$oldVersion\"",
        "product=\"$brand\"",
        "platform=\"$platform\"",
        "build_id=\"$oldBuildid\"",
        "locales=\"af en-US gu-IN ja uk\"",
        "channel=\"betatest\"",
        "from=\"$oldFromBuild\"",
        "aus_server=\"$ausServer\"",
        "ftp_server=\"$stagingServer/pub/mozilla.org\"",
        "to=\"$oldToBuild\""
    );

    open(CONFIG, ">$referenceConfig");
    print CONFIG "# $oldVersion $osname\n";
    print CONFIG join(' ', @oldRelease) . "\n";
    if ( ! $majorMode ) {
        print CONFIG "# $oldOldVersion $osname\n";
        print CONFIG join(' ', @oldOldRelease); # without this newline diff
                                                # will think the files differ
                                                # even when they do not
    }
    close(CONFIG);
    
    # We need to build up the global config object before calling
    # BumpVerifyConfig
    $config{'osname'} = $osname;
    $config{'product'} = $product;
    $config{'brand'} = $brand;
    $config{'old-version'} = $oldVersion;
    $config{'old-app-version'} = $oldVersion;
    $config{'old-long-version'} = $oldLongVersion;
    $config{'version'} = $version;
    $config{'app-version'} = $version;
    $config{'long-version'} = $longVersion;
    $config{'build-number'} = $build;
    $config{'aus-server-url'} = $ausServer;
    $config{'staging-server'} = $stagingServer;
    $config{'verify-config'} = $bumpedConfig;
    $config{'old-candidates-dir'} = $oldCandidatesDir;
    $config{'shipped-locales'} = $shippedLocales;
    $config{'linux-extension'} = $linuxExtension;
    $config{'pretty-candidates-dir'} = $prettyCandidatesDir;
    $config{'major'} = $majorMode;

    BumpVerifyConfig();

    system("diff -au $referenceConfig $bumpedConfig > $diffFile");
    if ($? != 0) {
        print "FAIL: \n";
        print "  Bumped file and reference file differ. Please inspect " .
                "$diffFile for details.\n";
    }
    else {
        print "PASS\n";
        # Now, cleanup the tempdir
        rmtree($workdir);
    }
}
