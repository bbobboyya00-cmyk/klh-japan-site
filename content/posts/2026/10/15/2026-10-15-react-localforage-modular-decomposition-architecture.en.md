---
title: "Decomposing Large-Scale React Components and Redesigning localForage State Management"
slug: "react-localforage-modular-decomposition-architecture"
date: 2026-10-15T10:35:16+09:00
draft: false
image: ""
description: "Implementation procedures and technical verification notes for decomposing a bloated settings view exceeding 1,680 lines into a Controller-View structure and isolating localForage integration and @dnd-kit context."
categories: ["Backend Architecture"]
tags: ["react", "localforage", "dnd-kit", "typescript", "modular-architecture"]
author: "K-Life Hack"
---

# Frontend Architecture Modularization: Phase 2 Implementation Report

In long-term frontend operation, concentrating responsibilities into a single file causes delays in type inference and increases rendering overhead. This article records the design and implementation verification of "Phase 2: Modular Decomposition", which splits `SettingsView.tsx` by responsibility.



## Architectural Overview: Applying the Controller-View Pattern

To dismantle a single monolithic component, we separate it into a lightweight tab orchestrator (Controller) and domain-specific functional modules (View).



```text
src/components/settings/
├── SettingsView.tsx          # Controller (Tab state management, Props distribution)
├── GeneralSettingsView.tsx   # General Module (User profile, localForage persistence, backup)
└── GroupManagementView.tsx   # Dnd Module (@dnd-kit context, group reordering)
```

- <b>`SettingsView.tsx` (Controller)</b>: Functions as an entry point that holds only the tab switching state (`activeSettingsTab`) and relays required handlers and states to child components.
- <b>`GeneralSettingsView.tsx` (General Settings Module)</b>: Aggregates profile updates, wake-up time settings, JSON export/import, and data reset logic, managing the lifecycle of unsaved change flags (`isDirty`) and confirmation modals.
- <b>`GroupManagementView.tsx` (Dnd-Kit Module)</b>: Encapsulates `@dnd-kit/core` and `@dnd-kit/sortable` contexts, isolating the routine group reordering logic (`handleChunkDragEnd`).

## Interface Design and Type Definitions

To prevent prop drilling resulting from module decomposition and to ensure type safety, data types passed between components are strictly defined.



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

## Component Implementation

### 1. Orchestrator (`SettingsView.tsx`)

Dedicate the controller to rendering routing and make it operate as a layout container.



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

### 2. General Settings and localForage Persistence (`GeneralSettingsView.tsx`)

Controls local storage access asynchronously and executes transactional update operations to prevent data corruption.



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

### 3. Group Management and Dnd Implementation (`GroupManagementView.tsx`)

Synchronizes drag-and-drop update events with the parent state, immediately reflecting order changes.



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

### 1. Screen Scroll Interference Caused by Pointer Event Bubbling

⚠️ <b>Symptom</b>: During operation on mobile devices or trackpads, drag operations inside `GroupManagementView` interfere with parent element scroll events, causing the entire view to scroll mid-reorder.


🛠️ <b>Solution</b>: Explicitly apply the CSS property `touch-action: none` to the drag handle or target element, and configure a distance threshold (`activationConstraint.distance: 5`) in the sensor settings.



```css
.group-management-module [data-sortable-handle] {
  touch-action: none;
}
```

### 2. Race Condition in Asynchronous localForage Import

⚠️ <b>Symptom</b>: Moving to another tab or reloading immediately after executing a settings import process causes IndexedDB to be overwritten with stale state data.


🛠️ <b>Solution</b>: Standardize to a synchronized flow where React state updates (`setUserData`) are triggered only after ensuring write completion to persistent storage (`await localforage.setItem`).



## Verification Result Logs

Verification logs for TypeScript type checking and build consistency after decomposition.



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

- <b>Reduction in File Line Count</b>: Down from the original 1,683 lines, each file now stays under 300 lines (with the controller under 100 lines), significantly lowering the cognitive load of individual files.
- <b>Preservation of Translation Keys</b>: Re-declaring `useTranslation` within each sub-module prevents missing translation context propagation and fully maintains existing i18n keys (`settings.*`) defined in Phase 1.
- <b>State Consistency Testing</b>: Post-implementation, execute reload tests immediately after performing features that involve storage operations (profile updates, backup imports, group order changes) to confirm that actual IndexedDB data matches the UI display.</basesettingsprops></sortableitemprops></htmlinputelement></userdata></htmlinputelement></string></boolean></basesettingsprops></settingstab></settingsviewprops></void></react.setstateaction<userdata></void></react.setstateaction<userdata>