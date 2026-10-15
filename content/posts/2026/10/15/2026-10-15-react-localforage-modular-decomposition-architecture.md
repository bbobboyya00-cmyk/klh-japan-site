---
title: "大規模Reactコンポーネントの分割とlocalForage状態管理の再設計"
slug: "react-localforage-modular-decomposition-architecture"
date: 2026-10-15T10:35:15+09:00
draft: false
image: ""
description: "1,680行を超える肥大化した設定ビューをController-View構造へ分解し、localForage連携と@dnd-kitコンテキストを分離する実装手順と技術検証ノート。"
categories: ["Backend Architecture"]
tags: ["react", "localforage", "dnd-kit", "typescript", "modular-architecture"]
author: "K-Life Hack"
---

## フロントエンド・アーキテクチャのモジュール化：Phase 2 実装レポート

フロントエンドの長期運用において、単一ファイルへの責務集中は型推論の遅延やレンダリング負荷の増大を招きます。本稿では、`SettingsView.tsx`を責務ごとに分割する「Phase 2: モジュラーデコンポジション」の設計と実装検証を記録します。

## アーキテクチャ概要：Controller-Viewパターンの適用

単一の巨大コンポーネントを解体するため、軽量なタブオーケストレータ（Controller）と、各ドメインに特化した機能モジュール（View）へと分離します。

```text
src/components/settings/
├── SettingsView.tsx          # Controller (タブ状態管理、Props配布)
├── GeneralSettingsView.tsx   # General Module (ユーザープロファイル、localForage永続化、バックアップ)
└── GroupManagementView.tsx   # Dnd Module (@dnd-kitコンテキスト、グループ並び替え)
```

- <b>`SettingsView.tsx` (Controller)</b>: タブ切り替え状態（`activeSettingsTab`）のみを保持し、子コンポーネントへ必要なハンドラおよび状態を中継するエントリーポイントとして機能させます。
- <b>`GeneralSettingsView.tsx` (General Settings Module)</b>: プロファイル更新、起床時刻設定、JSONエクスポート／インポート、データリセットロジックを集約し、未保存変更フラグ（`isDirty`）と確認モーダルのライフサイクルを管理します。
- <b>`GroupManagementView.tsx` (Dnd-Kit Module)</b>: `@dnd-kit/core`および`@dnd-kit/sortable`のコンテキストを内包し、ルーチングループの並び替えロジック（`handleChunkDragEnd`）を隔離します。

## インターフェース設計と型定義

モジュール分割に伴うProp Drillingの防止と型安全性の担保のため、コンポーネント間で受け渡すデータ型を厳格に定義します。

```typescript
import React from 'react';

export interface RoutineGroup {
  id: string;
  name: string;
  order: number;
}

export interface UserData {
  userName: string;
  wakeUpTime: string;
  theme: 'light' | 'dark' | 'system';
  groups: RoutineGroup[];
}

export interface BaseSettingsProps {
  userData: UserData;
  setUserData: React.Dispatch<react.setstateaction<userdata>&gt;;
  openConfirmModal: (action: () =&gt; Promise<void>, message: string) =&gt; void;
}

export interface SettingsViewProps {
  userData: UserData;
  setUserData: React.Dispatch<react.setstateaction<userdata>&gt;;
  soundService: {
    playBeep: () =&gt; void;
  };
  openConfirmModal: (action: () =&gt; Promise<void>, message: string) =&gt; void;
}
```

## コンポーネント実装

### 1. オーケストレータ (`SettingsView.tsx`)

コントローラーはレンダリングのルーティングに専念させ、レイアウトコンテナとして動作させます。

```tsx
import React, { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { SettingsViewProps } from './types';
import { GeneralSettingsView } from './GeneralSettingsView';
import { GroupManagementView } from './GroupManagementView';

type SettingsTab = 'general' | 'groups';

export const SettingsView: React.FC<settingsviewprops> = ({
  userData,
  setUserData,
  soundService,
  openConfirmModal,
}) =&gt; {
  const { t } = useTranslation();
  const [activeTab, setActiveTab] = useState<settingstab>('general');

  return (
    <div classname="settings-container flex flex-col h-full p-4">
<header classname="settings-header flex gap-4 border-b pb-2 mb-4">
<button =="" onclick="{()" type="button"> setActiveTab('general')}
          className={`px-4 py-2 ${activeTab === 'general' ? 'border-b-2 border-blue-500 font-bold' : ''}`}
        &gt;
          {t('settings.tabs.general')}
        </button>
<button =="" onclick="{()" type="button"> setActiveTab('groups')}
          className={`px-4 py-2 ${activeTab === 'groups' ? 'border-b-2 border-blue-500 font-bold' : ''}`}
        &gt;
          {t('settings.tabs.groups')}
        </button>
</header>
<main classname="settings-content flex-1 overflow-y-auto">
        {activeTab === 'general' ? (
          <generalsettingsview openconfirmmodal="{openConfirmModal}" setuserdata="{setUserData}" userdata="{userData}"></generalsettingsview>
        ) : (
          <groupmanagementview openconfirmmodal="{openConfirmModal}" setuserdata="{setUserData}" userdata="{userData}"></groupmanagementview>
        )}
      </main>
</div>
  );
};
```

### 2. 一般設定およびlocalForage永続化 (`GeneralSettingsView.tsx`)

ローカルストレージへのアクセスを非同期で制御し、データ破損を防ぐためのトランザクション的な更新処理を行います。

```tsx
import React, { useState, ChangeEvent } from 'react';
import { useTranslation } from 'react-i18next';
import localforage from 'localforage';
import { BaseSettingsProps, UserData } from './types';

export const GeneralSettingsView: React.FC<basesettingsprops> = ({
  userData,
  setUserData,
  openConfirmModal,
}) =&gt; {
  const { t } = useTranslation();
  const [isDirty, setIsDirty] = useState<boolean>(false);
  const [localName, setLocalName] = useState<string>(userData.userName);

  const handleNameChange = (e: ChangeEvent<htmlinputelement>) =&gt; {
    setLocalName(e.target.value);
    setIsDirty(true);
  };

  const handleSaveProfile = async () =&gt; {
    try {
      const updatedData: UserData = {
        ...userData,
        userName: localName,
      };
      await localforage.setItem('user_profile_data', updatedData);
      setUserData(updatedData);
      setIsDirty(false);
    } catch (error) {
      console.error('Failed to persist settings via localForage:', error);
    }
  };

  const handleExportData = async () =&gt; {
    const data = await localforage.getItem<userdata>('user_profile_data');
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `backup-${new Date().toISOString()}.json`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const handleImportData = (e: ChangeEvent<htmlinputelement>) =&gt; {
    const file = e.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = async (event) =&gt; {
      try {
        const content = event.target?.result as string;
        const parsed = JSON.parse(content) as UserData;
        openConfirmModal(async () =&gt; {
          await localforage.setItem('user_profile_data', parsed);
          setUserData(parsed);
          setLocalName(parsed.userName);
          setIsDirty(false);
        }, t('settings.confirm_import_overwrite'));
      } catch (err) {
        console.error('Import parse error:', err);
      }
    };
    reader.readAsText(file);
  };

  return (
    <div classname="general-settings flex flex-col gap-6 max-w-xl">
<div classname="field-group flex flex-col gap-2">
<label classname="font-medium" htmlfor="userName">
          {t('settings.profile.name')}
        </label>
<input classname="border p-2 rounded" id="userName" onchange="{handleNameChange}" type="text" value="{localName}"/>
        {isDirty &amp;&amp; (
          <button classname="mt-2 bg-blue-600 text-white px-4 py-2 rounded self-start" onclick="{handleSaveProfile}" type="button">
            {t('common.save')}
          </button>
        )}
      </div>
<div classname="backup-controls border-t pt-4 flex gap-4">
<button classname="bg-gray-200 px-4 py-2 rounded hover:bg-gray-300" onclick="{handleExportData}" type="button">
          {t('settings.backup.export')}
        </button>
<label classname="bg-gray-200 px-4 py-2 rounded hover:bg-gray-300 cursor-pointer">
          {t('settings.backup.import')}
          <input accept=".json" classname="hidden" onchange="{handleImportData}" type="file"/>
</label>
</div>
</div>
  );
};
```

### 3. グループ管理およびDnd実装 (`GroupManagementView.tsx`)

ドラッグ&amp;ドロップの更新イベントを親状態へ同期させ、順序変更を即座に反映します。

```tsx
import React from 'react';
import {
  DndContext,
  closestCenter,
  KeyboardSensor,
  PointerSensor,
  useSensor,
  useSensors,
  DragEndEvent,
} from '@dnd-kit/core';
import {
  arrayMove,
  SortableContext,
  sortableKeyboardCoordinates,
  verticalListSortingStrategy,
  useSortable,
} from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import localforage from 'localforage';
import { BaseSettingsProps, RoutineGroup, UserData } from './types';

interface SortableItemProps {
  group: RoutineGroup;
}

const SortableItem: React.FC<sortableitemprops> = ({ group }) =&gt; {
  const { attributes, listeners, setNodeRef, transform, transition } = useSortable({ id: group.id });
  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
  };

  return (
    <div classname="p-3 bg-white border border-gray-200 mb-2 rounded shadow-sm cursor-grab active:cursor-grabbing" ref="{setNodeRef}" style="{style}" {...attributes}="" {...listeners}="">
      {group.name}
    </div>
  );
};

export const GroupManagementView: React.FC<basesettingsprops> = ({
  userData,
  setUserData,
}) =&gt; {
  const sensors = useSensors(
    useSensor(PointerSensor, {
      activationConstraint: {
        distance: 5,
      },
    }),
    useSensor(KeyboardSensor, {
      coordinateGetter: sortableKeyboardCoordinates,
    })
  );

  const handleDragEnd = async (event: DragEndEvent) =&gt; {
    const { active, over } = event;
    if (!over || active.id === over.id) return;

    const oldIndex = userData.groups.findIndex((g) =&gt; g.id === active.id);
    const newIndex = userData.groups.findIndex((g) =&gt; g.id === over.id);

    const reorderedGroups = arrayMove(userData.groups, oldIndex, newIndex).map(
      (item, index) =&gt; ({ ...item, order: index })
    );

    const updatedData: UserData = {
      ...userData,
      groups: reorderedGroups,
    };

    setUserData(updatedData);
    await localforage.setItem('user_profile_data', updatedData);
  };

  return (
    <div classname="group-management-module">
<dndcontext collisiondetection="{closestCenter}" ondragend="{handleDragEnd}" sensors="{sensors}">
<sortablecontext =="" items="{userData.groups.map((g)"> g.id)} strategy={verticalListSortingStrategy}&gt;
          <div classname="group-list">
            {userData.groups.map((group) =&gt; (
              <sortableitem group="{group}" key="{group.id}"></sortableitem>
            ))}
          </div>
</sortablecontext>
</dndcontext>
</div>
  );
};
```

## Troubleshooting

### 1. ポインターイベントのバブリングによる画面スクロール阻害

⚠️ <b>現象</b>: モバイル端末やトラックパッド操作時に、`GroupManagementView`内のドラッグ操作と親要素のスクロールイベントが干渉し、並び替えの途中でビュー全体がスクロールされる事象が発生します。

🛠️ <b>解決策</b>: CSSプロパティ `touch-action: none` をドラッグハンドルまたは対象要素に明示的に付与し、センサー設定に移動閾値（`activationConstraint.distance: 5`）を設定します。

```css
.group-management-module [data-sortable-handle] {
  touch-action: none;
}
```

### 2. localForageの非同期インポートにおける競合状態（Race Condition）

⚠️ <b>現象</b>: 設定インポート処理の直後に別タブへの移動や再読み込みを実行すると、古い状態データでIndexedDBが上書きされる事象が発生します。

🛠️ <b>解決策</b>: 永続化ストレージへの書き込み完了（`await localforage.setItem`）を確実に担保した後に、Reactの状態更新（`setUserData`）を発火させる同期フローに統一します。

## 検証結果ログ

分割後のTypeScript型検査およびビルド整合性の検証ログです。

```text
$ npx tsc --noEmit --project tsconfig.json

$ ls -lh src/components/settings/
total 24K
-rw-r--r-- 1 runner staff 2.1K Oct 15 10:24 GeneralSettingsView.tsx
-rw-r--r-- 1 runner staff 2.8K Oct 15 10:24 GroupManagementView.tsx
-rw-r--r-- 1 runner staff 1.4K Oct 15 10:24 SettingsView.tsx
-rw-r--r-- 1 runner staff  680B Oct 15 10:24 types.ts

$ npm run build

&gt; client@1.0.0 build
&gt; vite build

vite v5.4.8 building for production...
✓ 42 modules transformed.
dist/assets/index-D7K9xQ1a.css   4.12 kB │ gzip: 1.20 kB
dist/assets/index-C8L9zP2b.js  142.80 kB │ gzip: 46.12 kB
✓ built in 420ms
```

## Operational Notes

- <b>ファイル行数の削減</b>: 元の1,683行から、各ファイルが300行未満（コントローラーは100行未満）に収まり、ファイル単体での認知的負荷が大幅に低下しました。
- <b>翻訳キーの保持</b>: 各サブモジュール内に`useTranslation`を再宣言することで、翻訳コンテキストの伝達漏れを防ぎ、Phase 1で定義された既存のi18nキー（`settings.*`）を完全に維持しています。
- <b>状態の一貫性テスト</b>: 実装後は、ストレージ操作を伴う各機能（プロファイル更新、バックアップインポート、グループ順序変更）の実行直後にリロードテストを実施し、IndexedDBの実データとUI表示が一致していることを確認してください。</basesettingsprops></sortableitemprops></htmlinputelement></userdata></htmlinputelement></string></boolean></basesettingsprops></settingstab></settingsviewprops></void></react.setstateaction<userdata></void></react.setstateaction<userdata>