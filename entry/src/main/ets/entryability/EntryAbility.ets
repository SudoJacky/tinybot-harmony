import { Diagnostics } from '../model/Diagnostics';
import { webview } from '@kit.ArkWeb';
import { ShareInbox } from '../services/NativeActions';
import { LanguagePreferences } from '../services/LanguagePreferences';
import { AppearancePreferences } from '../services/AppearancePreferences';
import { McpOAuth } from '../services/McpOAuth';
import { LaunchActions } from '../services/LaunchActions';
import { DeveloperDiagnostics } from '../services/DeveloperDiagnostics';
import { huaweiAccount } from '../services/HuaweiAccount';

import { hostedPrivacy } from '../services/HostedPrivacy';
import { backgroundGeneration } from '../services/BackgroundGeneration';
import { WebUiPreflight } from '../services/WebUiPreflight';
import { PreviewCapture } from '../services/PreviewCapture';
/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, common, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

// Required by Pen Kit's system-provided handwriting component.
declare namespace globalThis {
  let _brushEngineContext: common.UIAbilityContext;
}

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;
  private servicesStarted: boolean = false;
  private pendingWants: Want[] = [];

  // Pages extend their backgrounds under the system bars, so match the status bar text to the theme.
  private applySystemBars(): void {
    if (!this.mainWindow) {
      return;
    }
    const dark = AppStorage.get<boolean>('tinybot.appearance.dark') === true;
    this.mainWindow.setWindowSystemBarProperties({ statusBarContentColor: dark ? '#FFFFFF' : '#000000' })
      .catch((err: Error) => Diagnostics.log('error', 'app', 'bar_failed', undefined, err));
  }

  onConfigurationUpdate(config: Configuration): void {
    LanguagePreferences.refresh();
    AppearancePreferences.refresh(config);
    // The callback receives the new theme before context.config is refreshed.
    this.applySystemBars();
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    globalThis._brushEngineContext = this.context;
    LanguagePreferences.initialize(this.context);
    AppearancePreferences.initialize(this.context);
    this.pendingWants.push(want);
    // AppGallery presents startup consent automatically. A second request would stack two system dialogs.
    hostedPrivacy.initialize(this.context, (allowed: boolean) => {
      if (allowed) { this.startServices(); }
      else { DeveloperDiagnostics.stop(); }
    });
    Diagnostics.log('info', 'app', 'created');
  }





  private startServices(): void {
    if (!this.servicesStarted) {
      this.servicesStarted = true;
      DeveloperDiagnostics.initialize(this.context);
      // Prepare ArkWeb only after system consent, before mounting generated surfaces.
      const webStarted = Date.now();
      Diagnostics.log('info', 'web', 'engine_start');
      webview.WebviewController.initializeWebEngine();
      if (Diagnostics.acceptsLog('info')) { Diagnostics.log('info', 'web', 'engine_ready', { elapsedMs: Date.now() - webStarted }); }
    }
    for (const want of this.pendingWants) { this.receiveWant(want); }
    this.pendingWants = [];
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hostedPrivacy.refresh();
    if (!hostedPrivacy.allowed) { this.pendingWants.push(want); return; }
    this.receiveWant(want);
  }

  private receiveWant(want: Want): void {
    McpOAuth.receive(want.uri || '');
    ShareInbox.receive(want, this.context.getApplicationContext().filesDir);
    LaunchActions.receive(want);
  }

  onDestroy(): void {
    backgroundGeneration.dispose();
    hostedPrivacy.dispose();
    DeveloperDiagnostics.stop();
    Diagnostics.log('info', 'app', 'destroyed');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    Diagnostics.log('info', 'app', 'window_created');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Diagnostics.log('error', 'app', 'window_failed', undefined, err);
        return;
      }
      Diagnostics.log('info', 'app', 'window_loaded');
      this.mainWindow = windowStage.getMainWindowSync();
      AppearancePreferences.activate();
      this.applySystemBars();
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    Diagnostics.log('info', 'app', 'window_destroyed');
  }

  onForeground(): void {
    backgroundGeneration.setForeground(true);
    hostedPrivacy.refresh();
    if (hostedPrivacy.allowed) { huaweiAccount.refresh(); DeveloperDiagnostics.setForeground(true); }
    AppStorage.setOrCreate('tinybot.foreground', true);
    WebUiPreflight.setForeground(true);
    PreviewCapture.setForeground(true);
    LaunchActions.setForeground(true);
    LanguagePreferences.refresh();
    // Ability has brought to foreground
    Diagnostics.log('info', 'app', 'foreground');
  }

  onBackground(): void {
    WebUiPreflight.setForeground(false);
    PreviewCapture.setForeground(false);
    backgroundGeneration.setForeground(false);
    DeveloperDiagnostics.setForeground(false);
    AppStorage.setOrCreate('tinybot.foreground', false);
    LaunchActions.setForeground(false);
    // Ability has back to background
    Diagnostics.log('info', 'app', 'background');
  }
}
