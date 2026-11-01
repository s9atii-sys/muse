import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:clever_ads_solutions/clever_ads_solutions.dart';

import 'core.dart';

class AdClock {
  final double interstitialSeconds, repeatInterstitialSeconds, rewardSeconds, rewardDuration;
  double sinceInterstitial = 0, sinceReward = 0, adFree = 0;
  bool showing = false, _hasShownInterstitial = false;

  AdClock({
    this.interstitialSeconds = 10,
    this.repeatInterstitialSeconds = 30,
    this.rewardSeconds = 60,
    this.rewardDuration = 120,
  });

  double get _nextInterstitialAt =>
      _hasShownInterstitial ? repeatInterstitialSeconds : interstitialSeconds;

  bool get interstitialEligible =>
      !showing && adFree <= 0 && sinceInterstitial >= _nextInterstitialAt;

  bool get rewardEligible =>
      !showing && adFree <= 0 && sinceReward >= rewardSeconds;

  void tick(double seconds, {bool active = true}) {
    if (!active || showing || !seconds.isFinite || seconds <= 0) return;
    sinceInterstitial += seconds;
    sinceReward += seconds;
    adFree = math.max(0, adFree - seconds);
  }

  void start() {
    showing = true;
  }

  void finish({bool countInterstitial = false}) {
    showing = false;
    if (countInterstitial) {
      _hasShownInterstitial = true;
      sinceInterstitial = 0;
    }
  }

  void earned() {
    adFree = rewardDuration;
    sinceReward = 0;
    sinceInterstitial = 0;
    _hasShownInterstitial = true;
  }
}

class MuseAds extends ChangeNotifier with WidgetsBindingObserver {
  final Json config;
  late final AdClock clock;
  CASInterstitial? _interstitial;
  CASRewarded? _rewarded;
  Timer? _timer;
  bool _closed = false,
      _started = false,
      _foreground = true,
      _consentBusy = false,
      _canRequest = false,
      _showPending = false;
  bool privacyRequired = false;
  String status = 'CAS.AI is not initialized';
  final Stopwatch _watch = Stopwatch();
  double _last = 0;

  MuseAds(this.config) {
    clock = AdClock(
      interstitialSeconds: numv(config['interstitialSeconds'], 10)
          .clamp(10, 3600)
          .toDouble(),
      repeatInterstitialSeconds: numv(config['interstitialRepeatSeconds'], 30)
          .clamp(30, 3600)
          .toDouble(),
      rewardSeconds: numv(config['rewardOfferSeconds'], 60)
          .clamp(60, 3600)
          .toDouble(),
      rewardDuration: numv(config['rewardedAdFreeSeconds'], 120)
          .clamp(1, 3600)
          .toDouble(),
    );
  }

  String get casId => str(config['casId']);
  bool get testMode => flag(config['testMode'], true);
  bool get childDirected => flag(config['childDirected'], true);
  bool get rewardReady =>
      _canRequest &&
      !_consentBusy &&
      _foreground &&
      clock.rewardEligible &&
      _rewarded != null;

  String? get configurationError =>
      casId.isEmpty ? 'CAS.AI app ID is missing from ad-config.json.' : null;

  void _update([String? message]) {
    if (_closed) return;
    if (message != null) status = message;
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_closed || _started || !(Platform.isIOS || Platform.isAndroid)) return;
    _started = true;
    if (configurationError != null) {
      _update(configurationError);
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    _watch.start();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final now = _watch.elapsedMicroseconds / 1000000;
      clock.tick(now - _last, active: _foreground && !_consentBusy);
      _last = now;
      _update();
    });
    await _initializeSdk();
  }

  Future<void> _initializeSdk() async {
    if (_closed) return;
    _consentBusy = true;
    _update('Initializing CAS.AI and checking privacy choices…');
    try {
      if (kDebugMode) {
        await CASMobileAds.setDebugLoggingEnabled(true);
      }
      final result = await CASMobileAds.initialize(
        casId: casId,
        targetAudience:
            childDirected ? Audience.children : Audience.notChildren,
        showConsentFormIfRequired: true,
        forceTestAds: kDebugMode || testMode,
      );
      if (_closed) return;
      privacyRequired = result.isPrivacyOptionsRequired;
      if (result.error != null) {
        _canRequest = false;
        _consentBusy = false;
        _update('CAS.AI initialization failed: ${result.error}');
        return;
      }
      _canRequest = true;
      _consentBusy = false;
      _loadAds();
      _update(testMode || kDebugMode
          ? 'CAS.AI initialized · test ads enabled'
          : 'CAS.AI mediation initialized');
    } catch (e) {
      _canRequest = false;
      _consentBusy = false;
      _update('CAS.AI unavailable: $e');
    }
  }

  void _loadAds() {
    if (_closed || !_canRequest) return;

    _interstitial ??= CASInterstitial.createAndLoad(
      autoReload: true,
      minInterval: clock.repeatInterstitialSeconds.round(),
      placement: 'editor_interstitial',
      onAdLoaded: (ad) => _update('CAS.AI interstitial ready'),
      onAdFailedToLoad: (ad, error) =>
          _update('CAS.AI interstitial load failed: ${error.message}'),
      onAdFailedToShow: (ad, error) {
        clock.finish();
        _update('CAS.AI interstitial could not show: ${error.message}');
      },
      onAdShowed: (ad) => _update('CAS.AI interstitial showing'),
      onAdDismissed: (ad) {
        clock.finish(countInterstitial: true);
        _update('CAS.AI interstitial dismissed');
      },
    );

    _rewarded ??= CASRewarded.createAndLoad(
      autoReload: true,
      placement: 'ad_free_reward',
      onAdLoaded: (ad) => _update('CAS.AI rewarded ad ready'),
      onAdFailedToLoad: (ad, error) =>
          _update('CAS.AI rewarded load failed: ${error.message}'),
      onAdFailedToShow: (ad, error) {
        clock.finish();
        _update('CAS.AI rewarded ad could not show: ${error.message}');
      },
      onAdShowed: (ad) => _update('CAS.AI rewarded ad showing'),
      onAdDismissed: (ad) {
        clock.finish();
        _update('CAS.AI rewarded ad dismissed');
      },
      onUserEarnedReward: (ad) {
        if (_closed) return;
        clock.earned();
        _update('Reward earned: ${clock.rewardDuration.round()} seconds without interstitials.');
      },
    );
  }

  Future<void> naturalBreak() async {
    if (_closed ||
        !_foreground ||
        _consentBusy ||
        !_canRequest ||
        !clock.interstitialEligible ||
        _interstitial == null ||
        _showPending) {
      return;
    }
    _showPending = true;
    try {
      final ad = _interstitial!;
      if (!await ad.isLoaded()) {
        _update('CAS.AI interstitial is not ready yet');
        return;
      }
      if (_closed || !_foreground || !clock.interstitialEligible) return;
      clock.start();
      await ad.show();
    } catch (e) {
      clock.finish();
      _update('CAS.AI interstitial error: $e');
    } finally {
      _showPending = false;
    }
  }

  bool showReward() {
    if (!rewardReady || _closed || _showPending) return false;
    _showPending = true;
    unawaited(_showReward());
    return true;
  }

  Future<void> _showReward() async {
    try {
      final ad = _rewarded;
      if (ad == null || !await ad.isLoaded()) {
        _update('Rewarded ad is not ready yet');
        return;
      }
      if (_closed || !_foreground || !clock.rewardEligible) return;
      clock.start();
      await ad.show();
    } catch (e) {
      clock.finish();
      _update('CAS.AI rewarded ad error: $e');
    } finally {
      _showPending = false;
    }
  }

  Future<void> privacyOptions() async {
    if (!privacyRequired || clock.showing || _closed) return;
    _consentBusy = true;
    _update('Opening privacy choices…');
    try {
      await ConsentFlow.create().show();
      _consentBusy = false;
      _update('Privacy choices updated');
    } catch (e) {
      _consentBusy = false;
      _update('Could not open privacy choices: $e');
    }
  }

  Future<void> retry() async {
    if (_closed || _consentBusy || clock.showing) return;
    _interstitial?.dispose();
    _interstitial = null;
    _rewarded?.dispose();
    _rewarded = null;
    _canRequest = false;
    await _initializeSdk();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _last = _watch.elapsedMicroseconds / 1000000;
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _interstitial?.dispose();
    _rewarded?.dispose();
    _watch.stop();
    super.dispose();
  }
}
