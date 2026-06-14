bool g_downscaling = false;
bool g_isSyncingSharedUpgrades = false;

class PlayerSummonedEntry
{
	UnitProducer@ m_prod;
	array<IOwnedUnit@> m_units;
	array<uint> m_weaponInfo;
	array<bool> m_save;
	array<SValue@> m_saveData;
	int m_maxSummons = 1;
}

class AppliedMissionBuff
{
	uint32 m_id;
	MissionBuff@ m_buff;
}

class ShopUpgradeLevel
{
	uint shopId;
	uint upgrId;
	UpgradeShopUpgrade@ upgrade;
	int level;
	
	ShopUpgradeLevel(uint shopId, uint upgrId, int level)
	{
		auto shop = UpgradeShop::Get(shopId);
		if (shop is null)
		{
			level = -1;
			return;
		}
		
		for (uint i = 0; i < shop.m_upgrades.length(); i++)
		{
			if (shop.m_upgrades[i].m_idHash == upgrId)
			{
				@upgrade = shop.m_upgrades[i];
				break;
			}
		}
		
		this.shopId = shopId;
		this.upgrId = upgrId;

		if (upgrade !is null)
			this.level = clamp(level, -1, upgrade.m_steps.length() - 1);
	}
}

class WeaponMasteryLevel
{
	WeaponMastery@ m_mastery;
	int m_level;
}

class PlayerRecord : IEventPlayerCollectedItem, IEventPlayerLostItem
{
	array<PlayerSummonedEntry@> summons;
	
	void RegisterSummon(IOwnedUnit@ unit, uint weaponInfo, bool save)
	{
		auto prod = unit.GetUnit().GetUnitProducer();
		for (uint i = 0; i < summons.length(); i++)
		{
			if (summons[i].m_prod !is prod)
				continue;
			
			summons[i].m_units.insertLast(unit);
			summons[i].m_weaponInfo.insertLast(weaponInfo);
			summons[i].m_save.insertLast(save);
			summons[i].m_saveData.insertLast(null);
			return;
		}
		
		PlayerSummonedEntry entry;
		@entry.m_prod = prod;
		entry.m_units.insertLast(unit);
		entry.m_weaponInfo.insertLast(weaponInfo);
		entry.m_save.insertLast(save);
		entry.m_saveData.insertLast(null);
		summons.insertLast(entry);
	}


	string name; //NOTE: This can be utf8!

	// Userdata that can be used by mods. This does NOT save by itself.
	dictionary userdata;

	uint8 peer;
	Guid id;
	bool local;
	Actor@ actor;

	uint currMission;
	MissionManager::MissionState currMissionState;
	uint currMissionRewardSeed;

	bool spawnPosSaved;
	vec2 spawnPos;


	PlayerStats currStats;
	PlayerModifierCollection modifiers;
	array<ActorBuffStackDefModified@> modStacks;

	StatCollection@ statsChar;
	StatCollection@ statsRun;


	pfloat hp;
	pfloat mana;
	pint dashCharges;
	pint potionChargesUsed;
	pint rerollsUsed;
	
	pfloat lockedHp;
	pint shadowCurses;
	Actor@ lastCurser;

	PlayerClass@ playerClass;
	PlayerVoice@ playerVoice;

	uint deadTime;
	PlayerCorpse@ corpse;
	array<Guid> soulLinked;
	
	pint pingCount;

	pint experience;
	pint level;
	pint ngp;
	pint shortcut;
	array<pint> materials;
	
	
	pint pickedStr;
	pint pickedDex;
	pint pickedInt;
	pint pickedFoc;
	pint pickedVit;
	
	pint elixirStr;
	pint elixirDex;
	pint elixirInt;
	pint elixirFoc;
	pint elixirVit;
	
	dictionary pickedSkills;
	dictionary pickedComboSkills;
	dictionary pickedTempSkills;
	
	Item::ItemSkillDef@ librarySkill;
	
	array<ShopUpgradeLevel@> shopUpgrades;
	array<WeaponMasteryLevel@> weaponMasteries;
	array<Item::Trinket@> attunedTrinkets;
	array<Item::MissionMapDef@> missionMaps;
	
	pint bonusStatPts;
	pint bonusSkillPts;


	SValue@ m_staticSave;


	EquippedItems@ equipped;
	EquipmentInventory@ equipInventory;
	TrinketInventory@ trinketInventory;
	ValuableInventory@ valuableInventory;
	array<AppliedMissionBuff@> missionBuffs;
	array<MissionBuff@> architectBuffs;
	dictionary keys;


	BitmapString@ playerNameText;
	array<uint> charFlags;

	PlayerColors@ skinColor;
	PlayerColors@ hairColor;
	array<PlayerPortraitPiece@> portrait;

	uint uniqueKey;
	int64 saveTime;


	PlayerRecord()
	{
		Initialize();
	}

	PlayerRecord(PlayerRecord@ base)
	{
		Initialize();
		
		peer = base.peer;
		id = base.id;
		local = base.local;
		@actor = base.actor;
	}

	void ResetStatsRun()
	{
		@statsRun = StatCollection(0, 0);
		Stats::InitializeCollection(statsRun);
	}

	void Initialize()
	{
		level = 0;

		//@statistics = Stats::LoadList("tweak/stats.sval");
		//@statisticsSession = Stats::LoadList("tweak/stats.sval");

		ResetStatsRun();
		
		@statsChar = StatCollection(0, 0);
		Stats::InitializeCollection(statsChar);
		
		pickedSkills.deleteAll();
		pickedComboSkills.deleteAll();
		pickedTempSkills.deleteAll();
		
		shopUpgrades.removeRange(0, shopUpgrades.length());
		weaponMasteries.removeRange(0, weaponMasteries.length());
		attunedTrinkets.removeRange(0, attunedTrinkets.length());
		missionMaps.removeRange(0, missionMaps.length());
		
		@equipped = EquippedItems(this);
		@equipInventory = EquipmentInventory(this);
		equipInventory.m_maxItems = 24;
		@trinketInventory = TrinketInventory(this);
		@valuableInventory = ValuableInventory(this);
		
		materials.removeRange(0, materials.length());
		while(materials.length() < MaterialType::Num)
			materials.insertLast(0);

		GameEvents::Subscribe(this);
		Hooks::Call("PlayerRecordConstructor", @this);
	}

	void ResetPlayerHealthMana()
	{
		hp = 1.0;
		mana = 1.0;
		
		if (actor !is null)
		{
			auto pb = cast<PlayerBase>(actor);
			if (pb !is null)
				pb.m_buffs.ClearAfflictions();
		}
	}

	void PickedCharacter()
	{
		ResetBuffs();
		ClearSummons();
		
		RefreshStats();
		SyncCharacter();
		SyncStatPoints();

		GameEvents::PlayerCreatedCharacter(this);
		Network::Message("PlayerCreatedCharacter").SendToAll();

		GetHUD().Refresh(this);

		Hooks::Call("PickedCharacter", @this);

		currMission = MissionManager::g_module.m_missionDefHash;
		currMissionState = MissionManager::g_module.m_missionState;
		currMissionRewardSeed = MissionManager::g_module.m_missionRewardSeed;
	}

	void SetCharFlag(uint nameHash, bool value, bool netSync = true)
	{
		if (value)
		{
			int idx = charFlags.find(nameHash);
			if (idx < 0)
				charFlags.insertLast(nameHash);
		}
		else
		{
			while(true)
			{
				int idx = charFlags.find(nameHash);
				if (idx >= 0)
					charFlags.removeAt(idx);
				else
					break;
			}
		}
		
		if (netSync)
			(Network::Message("SetCharFlag") << peer << nameHash << value).SendToAll();
	}

	int GetKeys(const string& in key)
	{
		int currNum = 0;
		if (!keys.get(key, currNum))
			return 0;
		
		return currNum;
	}

	void AddKeys(const string& in key, int num)
	{
		int currNum = 0;
		keys.get(key, currNum);
		keys.set(key, currNum + num);
	}

	bool HasCharFlag(uint nameHash)
	{
		return charFlags.find(nameHash) >= 0;
	}

	void ChangeClass(PlayerClass@ plrClass)
	{
		@playerClass = plrClass;
		
		ResetBuffs();
		ClearSummons();
		
		RefreshStats();
		SyncCharacter();
		
		RefreshModifiers();
		
		if (actor !is null)
		{
			auto pb = cast<PlayerBase>(actor);
			if (pb !is null)
				pb.Initialize(this);
		}
		
		GetHUD().RefreshSkillList(this);
		
		
		
		int spentOnSkills = 0;
		auto skillKeys = pickedSkills.getKeys();
		for (uint i = 0; i < skillKeys.length(); i++)
		{
			int lvl;
			if (!pickedSkills.get(skillKeys[i], lvl))
				continue;
			
			if (lvl == 0)
				continue;
			
			auto@ skillDef = playerClass.GetSkillDef(HashString(skillKeys[i]), true);
			if (skillDef is null)
			{
				pickedSkills.set(skillKeys[i], 0);
				continue;
			}
		}
	}

	void CreateCharacter(PlayerClass@ plrClass, const string &in charName, PlayerVoice@ plrVoice)
	{
		ResetBuffs();
		ClearSummons();
		
		@playerClass = plrClass;
		level = 1;
		hp = 1.0;
		mana = 1.0;

		@playerVoice = plrVoice;
		name = charName;

		while (true)
		{
			uniqueKey = randi();
			if (PersistentSaves::GetCharacter(uniqueKey) is null)
				break;
		}

		RefreshStats();

		for (uint i = 0; i < playerClass.m_startingEquipment.length(); i++)
		{
			auto equipmentBaseItem = Equipment::BaseItem::Get(playerClass.m_startingEquipment[i]);
			if (equipmentBaseItem is null)
				continue;
			
			Equipment::Item equip;
			equip.quality = Item::Quality::Common;
			@equip.baseItem = equipmentBaseItem;
			equip.Finalize(randf(), 1, 0, null, null);
			
			auto unequipped = equipped.Equip(equip);
			if (unequipped !is null)
				equipInventory.Add(unequipped);
		}

		if (skinColor is null)
			@skinColor = PlayerColors::GetDefaultColor(HashString("skin"));
		if (hairColor is null)
			@hairColor = PlayerColors::GetDefaultColor(HashString("hair"));

		RefreshStats();
		SyncCharacter();
		
		if (actor !is null)
		{
			auto pb = cast<PlayerBase>(actor);
			if (pb !is null)
				pb.Initialize(this);
		}
		
		SyncStatPoints();
		
		GameEvents::PlayerCreatedCharacter(this);
		Network::Message("PlayerCreatedCharacter").SendToAll();
		GetHUD().RefreshSkillList(this);

		Hooks::Call("CreateCharacter", @this);

		currMission = MissionManager::g_module.m_missionDefHash;
		currMissionState = MissionManager::g_module.m_missionState;
		currMissionRewardSeed = MissionManager::g_module.m_missionRewardSeed;

		CheckForLevelup();
	}

	void SetPortrait(array<PlayerPortraitPiece@>@ pieces)
	{
		portrait = pieces;
		GetHUD().RefreshPortrait(this);
		
		if (local)
		{
			array<int> plrPortrait;
			for (uint i = 0; i < pieces.length(); i++)
				plrPortrait.insertLast(pieces[i] is null ? 0 : pieces[i].m_idHash);
			
			(Network::Message("PlayerSetPortrait") << plrPortrait).SendToAll();
		}
	}

	void SyncStatPoints(int sendToPeer = -1)
	{
		if (sendToPeer == -1 && local)
			(Network::Message("PlayerSyncCharacterStats") << pickedStr << pickedDex << pickedInt << pickedFoc << pickedVit << bonusStatPts << bonusSkillPts).SendToAll();
		else if (sendToPeer != -1)
			(Network::Message("PlayerSyncCharacterStats") << pickedStr << pickedDex << pickedInt << pickedFoc << pickedVit << bonusStatPts << bonusSkillPts).SendToPeer(sendToPeer);
	}

	void SyncCharacter(int sendToPeer = -1)
	{
		if (playerClass is null)
			return;
		
		if (sendToPeer == -1 && local)
			(Network::Message("PlayerSyncCharacter") << name << playerClass.m_idHash << level << playerVoice.m_idHash).SendToAll();
		else if (sendToPeer != -1)
			(Network::Message("PlayerSyncCharacter") << name << playerClass.m_idHash << level << playerVoice.m_idHash).SendToPeer(sendToPeer);
	}

	void AddSoulLink(PlayerRecord@ linked)
	{
/*
		if (linked is null)
			return;
		
		for (uint i = 0; i < soulLinked.length(); i++)
			if (soulLinked[i] == linked.id)
				return;
		
		soulLinked.insertLast(linked.id);
*/
	}

	void KillSoulLinked()
	{
		for (uint l = 0; l < soulLinked.length(); l++)
		{
			for (uint i = 0; i < g_players.length(); i++)
			{
				auto player = g_players[i];
				if (player.id != soulLinked[l] || player.IsDead())
					continue;
				
				if (player.local)
					player.actor.Kill(actor, 0);
				else
					(Network::Message("KillFromSoulLink")).SendToPeer(player.peer);
			}
		}
		
		soulLinked.removeRange(0, soulLinked.length());
	}

	void Save(SValueBuilder &builder)
	{
		builder.PushInteger("unique-key", uniqueKey);

		try {
		print("Saving char " + uniqueKey + ", hp: " + hp + ", isDead: " + IsDead() + ", deadTime: " + deadTime + ", hasActor: " + (actor !is null));
		
		if (IsDead() || hp <= 0)
			builder.PushFloat("hp", -1);
		else
			builder.PushFloat("hp", hp);

		builder.PushFloat("mana", mana);
		builder.PushBoolean("dead", IsDead());
		builder.PushInteger("experience", experience);
		builder.PushInteger("level", level);
		builder.PushInteger("ngp", ngp);
		builder.PushInteger("shortcut", shortcut);
		builder.PushInteger("dash-charges", dashCharges);
		builder.PushInteger("potion-charges-used", potionChargesUsed);
		builder.PushInteger("rerolls-used", rerollsUsed);
		builder.PushInteger("shadow-curses", shadowCurses);
		builder.PushFloat("locked-hp", lockedHp);
		
		builder.PushInteger("curr-mission", currMission);
		builder.PushInteger("curr-mission-state", currMissionState);
		builder.PushInteger("curr-mission-reward-seed", currMissionRewardSeed);
		
		builder.PushLong("savetime", time());
		
		
		
		builder.PushArray("materials");
		for (uint i = 0; i < materials.length(); i++)
			builder.PushInteger(materials[i]);
		builder.PopArray();
		
		
		builder.PushInteger("picked-str", pickedStr);
		builder.PushInteger("picked-dex", pickedDex);
		builder.PushInteger("picked-int", pickedInt);
		builder.PushInteger("picked-foc", pickedFoc);
		builder.PushInteger("picked-vit", pickedVit);
		builder.PushInteger("elixir-str", elixirStr);
		builder.PushInteger("elixir-dex", elixirDex);
		builder.PushInteger("elixir-int", elixirInt);
		builder.PushInteger("elixir-foc", elixirFoc);
		builder.PushInteger("elixir-vit", elixirVit);
		builder.PushInteger("bonus-stats", bonusStatPts);
		builder.PushInteger("bonus-skills", bonusSkillPts);

		if (librarySkill !is null)
			builder.PushInteger("library-skill", librarySkill.m_idHash);


		} catch { PrintError("Exception when saving stats"); }

		builder.PushArray("flags");
		for (uint i = 0; i < charFlags.length(); i++)
			builder.PushInteger(charFlags[i]);
		builder.PopArray();

		if (actor !is null)
			builder.PushVector2("pos", xy(actor.m_unit.GetPosition()));

		builder.PushArray("equipped");
		try {
		equipped.Save(builder);
		} catch { PrintError("Exception when saving equipped"); }
		builder.PopArray();

		builder.PushArray("equipment");
		try {
		equipInventory.Save(builder);
		} catch { PrintError("Exception when saving equipment"); }
		builder.PopArray();

		builder.PushArray("trinkets");
		try {
		trinketInventory.Save(builder);
		} catch { PrintError("Exception when saving trinkets"); }
		builder.PopArray();


		builder.PushString("name", name);
		
		if (playerClass !is null)
			builder.PushString("class", playerClass.m_id);
		
		if (playerVoice !is null)
			builder.PushString("voice-id", playerVoice.m_id);




		builder.PushDictionary("keys");
		auto keyKeys = keys.getKeys();
		for (uint i = 0; i < keyKeys.length(); i++)
		{
			int num;
			if (!keys.get(keyKeys[i], num))
				continue;
			
			builder.PushInteger(keyKeys[i], num);
		}
		builder.PopDictionary();


		builder.PushDictionary("picked-skills");
		auto skillKeys = pickedSkills.getKeys();
		for (uint i = 0; i < skillKeys.length(); i++)
		{
			int lvl;
			if (!pickedSkills.get(skillKeys[i], lvl))
				continue;
			
			builder.PushInteger(skillKeys[i], lvl);
		}
		builder.PopDictionary();

		builder.PushDictionary("picked-combo-skills");
		auto comboSkillKeys = pickedComboSkills.getKeys();
		for (uint i = 0; i < comboSkillKeys.length(); i++)
		{
			int lvl;
			if (!pickedComboSkills.get(comboSkillKeys[i], lvl))
				continue;
			
			builder.PushInteger(comboSkillKeys[i], lvl);
		}
		builder.PopDictionary();


		builder.PushDictionary("picked-temp-skills");
		auto skillTmpKeys = pickedTempSkills.getKeys();
		for (uint i = 0; i < skillTmpKeys.length(); i++)
		{
			int lvl = 0;
			if (!pickedTempSkills.get(skillTmpKeys[i], lvl))
				continue;
			
			if (lvl == 0)
				continue;
			
			builder.PushInteger(skillTmpKeys[i], lvl);
		}
		builder.PopDictionary();

		builder.PushArray("weapon-masteries");
		for (uint i = 0; i < weaponMasteries.length(); i++)
		{
			if (weaponMasteries[i].m_level <= 0)
				continue;
			
			builder.PushInteger(weaponMasteries[i].m_mastery.m_idHash);
			builder.PushInteger(weaponMasteries[i].m_level);
			builder.PushInteger(0);
		}
		builder.PopArray();


		builder.PushArray("attuned-trinkets");
		for (uint i = 0; i < attunedTrinkets.length(); i++)
			builder.PushInteger(attunedTrinkets[i].m_idHash);
		builder.PopArray();

		builder.PushArray("mission-maps");
		for (uint i = 0; i < missionMaps.length(); i++)
			missionMaps[i].Save(builder);
		builder.PopArray();


		builder.PushArray("mission-buffs");
		for (uint i = 0; i < missionBuffs.length(); i++)
		{
			builder.PushInteger(missionBuffs[i].m_id);
			builder.PushInteger(missionBuffs[i].m_buff.m_idHash);
		}
		builder.PopArray();

		builder.PushArray("architect-buffs");
		for (uint i = 0; i < architectBuffs.length(); i++)
			builder.PushInteger(architectBuffs[i].m_idHash);
		builder.PopArray();

		valuableInventory.Save(builder);

		builder.PushArray("shop-upgrades");
		for (uint i = 0; i < shopUpgrades.length(); i++)
		{
			if (shopUpgrades[i].level < 0)
				continue;
			
			builder.PushInteger(shopUpgrades[i].shopId);
			builder.PushInteger(shopUpgrades[i].upgrId);
			builder.PushInteger(shopUpgrades[i].level);
		}
		builder.PopArray();


		builder.PushArray("soullinked");
		for (uint i = 0; i < soulLinked.length(); i++)
			builder.PushString(soulLinked[i]);
		builder.PopArray();


		builder.PushSimple("stats-char", statsChar.Save());
		builder.PushSimple("stats-run", statsRun.Save());


		builder.PushInteger("skin-color", skinColor is null ? -1 : skinColor.m_idHash);
		builder.PushInteger("hair-color", hairColor is null ? -1 : hairColor.m_idHash);

		builder.PushArray("portrait");
		try {
		for (uint i = 0; i < portrait.length(); i++)
			builder.PushInteger(portrait[i].m_idHash);
		} catch { PrintError("Exception when saving portrait"); }
		builder.PopArray();


		if (local)
		{
			builder.PushDictionary("architect-loadout");
			for (uint i = 0; i < MissionLoadout::Instances.length(); i++)
				MissionLoadout::Instances[i].Save(builder);
			builder.PopDictionary();
		}


		builder.PushArray("summons");
		try {
		for (uint i = 0; i < summons.length(); i++)
		{
			if (summons[i].m_units.length() <= 0)
				continue;
			
			builder.PushString(summons[i].m_prod.GetResourceName());
			auto@ weaponInfos = summons[i].m_weaponInfo;
			auto@ units = summons[i].m_units;
			auto@ saves = summons[i].m_save;
			//auto@ saveDatas = summons[i].m_saveData;
			for (uint j = 0; j < weaponInfos.length(); j++)
			{
				if (units[j] is null || !saves[j])
					continue;
				
				builder.PushInteger(weaponInfos[j]);
				
				SValueBuilder sb;
				sb.PushDictionary();
				units[j].SaveUnit(sb);
				builder.PushSimple(sb.Build());
			}
		}
		} catch { PrintError("Exception when saving summons"); }
		builder.PopArray();
		
		
		if (actor !is null)
		{
			auto plr = cast<PlayerBase>(actor);
			if (plr !is null)
			{
				builder.PushDictionary("actor-save");
				plr.m_buffs.Save(builder);
				
				builder.PushDictionary("skills");
				try {
				for (uint i = 0; i < plr.m_skills.length(); i++)
					plr.m_skills[i].Save(builder);
				} catch { PrintError("Exception when saving skills"); }
				builder.PopDictionary();
				builder.PopDictionary();
			}
		}

		try {
		Hooks::Call("PlayerRecordSave", @this, builder);
		} catch { PrintError("Exception when saving player record via hooks"); }
	}

	bool Load(SValue@ data, StartMode sMode)
	{
		UnitPtr u;

		uniqueKey = GetParamInt(u, data, "unique-key", false, uniqueKey);
		hp = GetParamFloat(u, data, "hp", false, 1.0);
		mana = GetParamFloat(u, data, "mana", false, 1.0);
		experience = GetParamInt(u, data, "experience", false, 0);
		level = GetParamInt(u, data, "level", false, 1);
		ngp = GetParamInt(u, data, "ngp", false, 0);
		shortcut = GetParamInt(u, data, "shortcut", false, 0);
		dashCharges = GetParamInt(u, data, "dash-charges", false, 0);
		potionChargesUsed = GetParamInt(u, data, "potion-charges-used", false, 0);
		rerollsUsed = GetParamInt(u, data, "rerolls-used", false, 0);
		shadowCurses = GetParamInt(u, data, "shadow-curses", false, 0);
		lockedHp = GetParamFloat(u, data, "locked-hp", false, 0.0);

		currMission = GetParamInt(u, data, "curr-mission", false, 0);
		currMissionState = MissionManager::MissionState(GetParamInt(u, data, "curr-mission-state", false, 0));
		currMissionRewardSeed = GetParamInt(u, data, "curr-mission-reward-seed", false, 0);

		saveTime = GetParamLong(u, data, "savetime", false, 0);



		auto materialsArr = GetParamArray(u, data, "materials", false);
		if (materialsArr !is null)
		{
			materials.removeRange(0, materials.length());
			for (uint i = 0; i < materialsArr.length(); i++)
				materials.insertLast(int(materialsArr[i].GetInteger()));
		}
		while(materials.length() < MaterialType::Num)
			materials.insertLast(0);

		pickedStr = GetParamInt(u, data, "picked-str", false, 0);
		pickedDex = GetParamInt(u, data, "picked-dex", false, 0);
		pickedInt = GetParamInt(u, data, "picked-int", false, 0);
		pickedFoc = GetParamInt(u, data, "picked-foc", false, 0);
		pickedVit = GetParamInt(u, data, "picked-vit", false, 0);
		elixirStr = GetParamInt(u, data, "elixir-str", false, 0);
		elixirDex = GetParamInt(u, data, "elixir-dex", false, 0);
		elixirInt = GetParamInt(u, data, "elixir-int", false, 0);
		elixirFoc = GetParamInt(u, data, "elixir-foc", false, 0);
		elixirVit = GetParamInt(u, data, "elixir-vit", false, 0);
		bonusStatPts = GetParamInt(u, data, "bonus-stats", false, 0);
		bonusSkillPts = GetParamInt(u, data, "bonus-skills", false, 0);

		bool dead = false;
		if (GetParamBool(u, data, "dead", false, false))
		{
			deadTime = 1;
			dead = true;
		}

		print("Loading char " + uniqueKey + ", hp: " + hp + ", isDead: " + dead + ", deadTime: " + deadTime + ", hasActor: " + (actor !is null));


		auto spawnPosData = data.GetDictionaryEntry("pos");
		if (spawnPosData is null)
			spawnPosSaved = false;
		else
		{
			spawnPosSaved = true;
			spawnPos = spawnPosData.GetVector2();
		}

		// Load main stats
		name = GetParamString(u, data, "name", false, name);

		equipped.Load(GetParamArray(u, data, "equipped", false));
		equipInventory.Load(GetParamArray(u, data, "equipment", false));
		trinketInventory.Load(GetParamArray(u, data, "trinkets", false));

		@playerClass = PlayerClass::Get(GetParamString(u, data, "class", false, ""));
		
		@playerVoice = PlayerVoice::Get(GetParamString(u, data, "voice-id", false, ""));
		if (playerVoice is null)
			@playerVoice = PlayerVoice::Instances[0];
		if (local && playerVoice.m_blockedByDLC)
			@playerVoice = playerVoice.CreateBogusVoice();



		auto keysData = data.GetDictionaryEntry("keys");
		if (keysData !is null)
		{
			keys.deleteAll();
			auto keysLoaded = keysData.GetDictionary();
			auto keyKeys = keysLoaded.getKeys();
			for (uint i = 0; i < keyKeys.length(); i++)
			{
				auto key = keyKeys[i];
				
				SValue@ keyDat;
				int num;
				if (keysLoaded.get(key, @keyDat))
					num = keyDat.GetInteger();
				
				if (num <= 0)
					continue;
				
				keys.set(key, num);
			}
		}


		if (playerClass !is null)
		{
			auto pickedSkillsData = data.GetDictionaryEntry("picked-skills");
			if (pickedSkillsData !is null)
			{
				pickedSkills.deleteAll();
				auto pickedSkillsLoaded = pickedSkillsData.GetDictionary();
				auto skillKeys = pickedSkillsLoaded.getKeys();
				for (uint i = 0; i < skillKeys.length(); i++)
				{
					auto key = skillKeys[i];
					
					SValue@ lvlDat;
					int lvl;
					if (pickedSkillsLoaded.get(key, @lvlDat))
						lvl = lvlDat.GetInteger();
					
					if (lvl == 0)
						continue;
					
					auto@ skillDef = playerClass.GetSkillDef(HashString(key));
					if (skillDef !is null)
						pickedSkills.set(key, clamp(lvl, 0, skillDef.m_levelParams.length()));
				}
			}
			
			auto pickedComboSkillsData = data.GetDictionaryEntry("picked-combo-skills");
			if (pickedComboSkillsData !is null)
			{
				pickedComboSkills.deleteAll();
				auto pickedSkillsLoaded = pickedComboSkillsData.GetDictionary();
				auto skillKeys = pickedSkillsLoaded.getKeys();
				for (uint i = 0; i < skillKeys.length(); i++)
				{
					auto key = skillKeys[i];
					
					SValue@ lvlDat;
					int lvl;
					if (pickedSkillsLoaded.get(key, @lvlDat))
						lvl = lvlDat.GetInteger();
					
					if (lvl == 0)
						continue;
					
					auto@ skillDef = PlayerSkillDef::Get(key);
					if (skillDef !is null)
						pickedComboSkills.set(key, clamp(lvl, 0, skillDef.m_levelParams.length()));
				}
			}
			
			
			
			auto pickedTempSkillsData = data.GetDictionaryEntry("picked-temp-skills");
			if (pickedTempSkillsData !is null)
			{
				pickedTempSkills.deleteAll();
				auto pickedSkillsLoaded = pickedTempSkillsData.GetDictionary();
				auto skillKeys = pickedSkillsLoaded.getKeys();
				for (uint i = 0; i < skillKeys.length(); i++)
				{
					auto key = skillKeys[i];
					
					SValue@ lvlDat;
					int lvl;
					if (pickedSkillsLoaded.get(key, @lvlDat))
						lvl = lvlDat.GetInteger();
					
					if (lvl == 0)
						continue;
					
					auto@ skillDef = playerClass.GetSkillDef(HashString(key));
					if (skillDef !is null)
						pickedTempSkills.set(key, clamp(lvl, 0, skillDef.m_levelParams.length()));
					else
						pickedTempSkills.set(key, lvl);
				}
			}
		}


		auto libSkillId = uint(GetParamInt(u, data, "library-skill", false));
		@librarySkill = Item::ItemSkillDef::Get(libSkillId);
		
		if (libSkillId == HashString("combo_kills"))
			pickedComboSkills.set("combo_kills", 1);
		else if (libSkillId == HashString("combo_dash"))
			pickedComboSkills.set("combo_dash", 1);
		else if (libSkillId == HashString("combo_parry"))
			pickedComboSkills.set("combo_parry", 1);


		auto weapMasteriesArr = GetParamArray(u, data, "weapon-masteries", false);
		if (weapMasteriesArr !is null)
		{
			weaponMasteries.removeRange(0, weaponMasteries.length());
			for (uint i = 0; i < weapMasteriesArr.length(); i += 3)
			{
				
				WeaponMasteryLevel mod;
				@mod.m_mastery = WeaponMastery::Get(uint(weapMasteriesArr[i].GetInteger()));
				mod.m_level = weapMasteriesArr[i + 1].GetInteger();
				//mod.m_unused = weapMasteriesArr[i + 2].GetInteger();
				
				if (mod.m_level <= 0)
					continue;
				
				if (mod.m_mastery is null)
					continue;
				
				weaponMasteries.insertLast(mod);
			}
		}

		auto attunedTrinketsArr = GetParamArray(u, data, "attuned-trinkets", false);
		if (attunedTrinketsArr !is null)
		{
			attunedTrinkets.removeRange(0, attunedTrinkets.length());
			for (uint i = 0; i < attunedTrinketsArr.length(); i++)
			{
				auto trinket = Item::Trinket::Get(uint(attunedTrinketsArr[i].GetInteger()));
				if (trinket !is null)
					attunedTrinkets.insertLast(trinket);
			}
		}

		auto missionMapsArr = GetParamArray(u, data, "mission-maps", false);
		if (missionMapsArr !is null)
		{
			missionMaps.removeRange(0, missionMaps.length());
			for (uint i = 0; i < missionMapsArr.length(); i++)
			{
				auto missionMap = Item::LoadMissionMapDef(missionMapsArr[i]);
				if (missionMap !is null)
					missionMaps.insertLast(missionMap);
			}
		}


		auto missionBuffsArr = GetParamArray(u, data, "mission-buffs", false);
		if (missionBuffsArr !is null)
		{
			missionBuffs.removeRange(0, missionBuffs.length());
			for (uint i = 0; i < missionBuffsArr.length(); i += 2)
			{
				AppliedMissionBuff mbuff;
				mbuff.m_id = uint(missionBuffsArr[i + 0].GetInteger());
				@mbuff.m_buff = MissionBuff::Get(uint(missionBuffsArr[i + 1].GetInteger()));
				
				if (mbuff.m_buff !is null)
					missionBuffs.insertLast(mbuff);
			}
		}

		auto architectBuffsArr = GetParamArray(u, data, "architect-buffs", false);
		if (architectBuffsArr !is null)
		{
			architectBuffs.removeRange(0, architectBuffs.length());
			for (uint i = 0; i < architectBuffsArr.length(); i++)
			{
				auto missionBuff = MissionBuff::Get(uint(architectBuffsArr[i].GetInteger()));
				if (missionBuff !is null)
					architectBuffs.insertLast(missionBuff);
			}
		}


		valuableInventory.Load(data);

		auto shopUpgrArr = GetParamArray(u, data, "shop-upgrades", false);
		if (shopUpgrArr !is null)
		{
			shopUpgrades.removeRange(0, shopUpgrades.length());
			for (uint i = 0; i < shopUpgrArr.length(); i += 3)
			{
				uint shopId = uint(shopUpgrArr[i + 0].GetInteger());
				uint upgrId = uint(shopUpgrArr[i + 1].GetInteger());
				int level = uint(shopUpgrArr[i + 2].GetInteger());
				if (level < 0)
					continue;
				
				SetShopUpgradeLevel(shopId, upgrId, level);
			}
		}


		auto flagsArr = GetParamArray(u, data, "flags", false);
		if (flagsArr !is null)
		{
			charFlags.removeRange(0, charFlags.length());
			for (uint i = 0; i < flagsArr.length(); i++)
				charFlags.insertLast(uint(flagsArr[i].GetInteger()));
		}

		auto soullinkedArr = GetParamArray(u, data, "soullinked", false);
		if (soullinkedArr !is null)
		{
			soulLinked.removeRange(0, soulLinked.length());
			for (uint i = 0; i < soullinkedArr.length(); i++)
				soulLinked.insertLast(Guid(soullinkedArr[i].GetString()));
		}

		if (playerClass !is null)
		{
			@skinColor = PlayerColors::Get(uint(GetParamInt(u, data, "skin-color", false, skinColor is null ? -1 : skinColor.m_idHash)));
			@hairColor = PlayerColors::Get(uint(GetParamInt(u, data, "hair-color", false, hairColor is null ? -1 : hairColor.m_idHash)));

			if (skinColor is null)
				@skinColor = PlayerColors::GetDefaultColor(HashString("skin"));
			if (hairColor is null)
				@hairColor = PlayerColors::GetDefaultColor(HashString("hair"));
		}

		auto portraitArr = GetParamArray(u, data, "portrait", false);
		if (portraitArr !is null)
		{
			portrait.removeRange(0, portrait.length());
			for (uint i = 0; i < portraitArr.length(); i++)
			{
				auto plrCol = PlayerPortraitPiece::Get(uint(portraitArr[i].GetInteger()));
				if (local && plrCol.m_blockedByDLC)
					@plrCol = plrCol.CreateBogusPortraitPiece();
				portrait.insertLast(plrCol);
			}
		}

		auto summonsArr = GetParamArray(u, data, "summons", false);
		if (summonsArr !is null)
		{
			for (uint i = 0; i < summons.length(); i++)
			{
				uint numSumm = summons[i].m_units.length();
				for (uint j = 0; j < numSumm; j++)
				{
					if (summons[i].m_units[j] !is null)
						summons[i].m_units[j].Destroy();
				}
			}
			summons.removeRange(0, summons.length());
			
			PlayerSummonedEntry@ toAdd = null;
			for (uint i = 0; i < summonsArr.length(); i++)
			{
				auto st = summonsArr[i].GetType();
				if (st == SValueType::String)
				{
					if (toAdd !is null && toAdd.m_prod !is null && toAdd.m_weaponInfo.length() > 0)
						summons.insertLast(toAdd);
					
					@toAdd = PlayerSummonedEntry();
					@toAdd.m_prod = Resources::GetUnitProducer(summonsArr[i].GetString());
				}
				else if (st == SValueType::Integer)
				{
					toAdd.m_weaponInfo.insertLast(uint(summonsArr[i].GetInteger()));
					toAdd.m_units.insertLast(null);
					toAdd.m_save.insertLast(true);
					toAdd.m_saveData.insertLast(summonsArr[++i]);
				}
			}
			
			if (toAdd !is null && toAdd.m_prod !is null && toAdd.m_weaponInfo.length() > 0)
				summons.insertLast(toAdd);
		}


		if (local)
		{
			for (uint i = 0; i < trinketInventory.m_items.length(); i++)
				trinketInventory.m_items[i].m_seen = true;
			
			auto archData = data.GetDictionaryEntry("architect-loadout");
			if (archData !is null)
			{
				for (uint i = 0; i < MissionLoadout::Instances.length(); i++)
					MissionLoadout::Instances[i].Load(this, archData);
			}
		}



		statsChar.Load(data.GetDictionaryEntry("stats-char"));
		Stats::InitializeCollection(statsChar);
		statsRun.Load(data.GetDictionaryEntry("stats-run"));
		Stats::InitializeCollection(statsRun);


		if (m_staticSave !is null)
			m_staticSave.Delete();
		@m_staticSave = data.GetDictionaryEntry("actor-save");
		if (m_staticSave !is null)
			@m_staticSave = m_staticSave.Copy();
		

		Hooks::Call("PlayerRecordLoad", @this, @data);

		if (actor !is null)
			cast<PlayerBase>(actor).Refresh();
		
		g_flags.RefreshItems(this);
		
		if (playerClass is null)
			return false;
      
    if (sMode != StartMode::Continue)
      SyncShopUpgradesWithOtherCharacters();
    
		return true;
	}

	void Clear()
	{
		if (m_staticSave !is null)
			m_staticSave.Delete();
		@m_staticSave = null;
		
		currStats.Cleanup();
	}

	void ClearSummons()
	{
		for (uint i = 0; i < summons.length(); i++)
		{
			for (uint j = 0; j < summons[i].m_units.length(); j++)
			{
				if (summons[i].m_units[j] !is null)
					summons[i].m_units[j].Destroy();
			}
		}
		summons.removeRange(0, summons.length());
	}

	int GetSkillLevel(PlayerSkillDef@ skillDef)
	{
		if (skillDef is null)
			return 0;
		
		int lvl = 0;
		if (!pickedSkills.get(skillDef.m_id, lvl))
		{
			if (!pickedComboSkills.get(skillDef.m_id, lvl))
				lvl = 0;
		}
		
		int lvlTmp = 0;
		if (!pickedTempSkills.get(skillDef.m_id, lvlTmp))
			lvlTmp = 0;
		
		return (lvl + lvlTmp) + skillDef.m_startingLevel;
	}

	int GetSkillPointsSpentOnSkills()
	{
		int spentOnSkills = 0;
		auto skillKeys = pickedSkills.getKeys();
		for (uint i = 0; i < skillKeys.length(); i++)
		{
			int lvl;
			if (!pickedSkills.get(skillKeys[i], lvl))
				continue;
			
			if (lvl == 0)
				continue;
			
			auto@ skillDef = playerClass.GetSkillDef(HashString(skillKeys[i]), true);
			if (skillDef is null)
				continue;
			
			lvl += skillDef.m_startingLevel;
			for (int j = skillDef.m_startingLevel; j < lvl; j++)
				spentOnSkills += skillDef.m_levelSkillCost[j];
		}
		
		return spentOnSkills;
	}

	int GetSkillPointsSpentOnComboSkills()
	{
		int spentOnSkills = 0;
		auto skillKeys = pickedComboSkills.getKeys();
		for (uint i = 0; i < skillKeys.length(); i++)
		{
			int lvl;
			if (!pickedComboSkills.get(skillKeys[i], lvl))
				continue;
			
			if (lvl == 0)
				continue;
			
			auto@ skillDef = PlayerSkillDef::Get(skillKeys[i]);
			if (skillDef is null)
				continue;
			
			lvl += skillDef.m_startingLevel;
			for (int j = skillDef.m_startingLevel; j < lvl; j++)
				spentOnSkills += skillDef.m_levelSkillCost[j];
		}
		
		return spentOnSkills;
	}


	int GetSkillPointsSpentOnWeaponMasteries(uint cat = 0)
	{
		int spentOnMasteries = 0;
		
		for (uint i = 0; i < weaponMasteries.length(); i++)
		{
			if (weaponMasteries[i].m_mastery.m_category != cat && cat != 0)
				continue;
			
			int cost = weaponMasteries[i].m_level + weaponMasteries[i].m_mastery.m_baseCost - 1;
			spentOnMasteries += cost * cost - (weaponMasteries[i].m_mastery.m_baseCost - 1) * (weaponMasteries[i].m_mastery.m_baseCost - 1);
		}
		
		return spentOnMasteries;
	}

	int GetSkillPointsSpentOnTrinketAttunement()
	{
		int spent = 0;
		for (uint i = 0; i < attunedTrinkets.length(); i++)
			spent += Item::GetTrinketAttuneCost(attunedTrinkets[i]);
		
		return spent;
	}

	int GetFreeSkillPoints()
	{
		int baseSkillpts = 0;
		if (local && g_myTownRecord !is null && g_myTownRecord.m_accomplishmentRewards !is null)
			baseSkillpts = g_myTownRecord.m_accomplishmentRewards.m_rSkillpt;
		
		return baseSkillpts + Tweak::StartSkillPts + (level - 1) * Tweak::SkillPtsPerLevel + bonusSkillPts - GetSkillPointsSpentOnSkills() - GetSkillPointsSpentOnComboSkills() - GetSkillPointsSpentOnWeaponMasteries() - GetSkillPointsSpentOnTrinketAttunement();
	}

	void SetLibrarySkill(Item::ItemSkillDef@ skill)
	{
		@librarySkill = skill;
		
		if (skill !is null)
			LootLog::PresentLibrarySkill(this, skill);
		
		if (actor !is null)
			cast<PlayerBase>(actor).LoadSkills();
		
		RefreshModifiers();
	}

	bool NetSyncSkillLevel(uint idHash, int newLevel, bool comboSkill)
	{
		auto@ skillDef = playerClass.GetSkillDef(idHash);
		if (skillDef is null || uint(skillDef.m_startingLevel + newLevel) > skillDef.m_levelParams.length())
			return false;
		
		if (comboSkill)
			pickedComboSkills.set(skillDef.m_id, newLevel);
		else
			pickedSkills.set(skillDef.m_id, newLevel);
		
		if (actor !is null)
		{
			cast<PlayerBase>(actor).LoadSkills();
			RefreshModifiers();
		}
		
		return true;
	}

	void ResetSkillTempLevels()
	{
		pickedTempSkills.deleteAll();
	}

	void RemoveTempSkill(const string &in id)
	{
		int currLevel = 0;
		if (!pickedTempSkills.get(id, currLevel))
			return;

		pickedTempSkills.delete(id);
	}

	void ResetBuffs()
	{
		if (actor is null)
			return;
		auto plr = cast<PlayerBase>(actor);
		if (plr is null)
			return;
		
		plr.m_buffs.Clear();
	}

	bool NetSyncSkillTempLevel(uint idHash, int newLevel)
	{
		auto@ skillDef = playerClass.GetSkillDef(idHash);
		if (skillDef is null || uint(skillDef.m_startingLevel + newLevel) > skillDef.m_levelParams.length())
			return false;
		
		LootLog::PresentSkillSphere(this, skillDef, GetSkillLevel(skillDef));
		pickedTempSkills.set(skillDef.m_id, newLevel);
		if (actor !is null)
		{
			cast<PlayerBase>(actor).LoadSkills();
			RefreshModifiers();
		}
		
		return true;
	}

	int GetMasteryWeaponCost(WeaponMastery@ mastery)
	{
		int level = 0;
		for (uint i = 0; i < weaponMasteries.length(); i++)
		{
			if (weaponMasteries[i].m_mastery is mastery && weaponMasteries[i].m_level > 0)
			{
				level = weaponMasteries[i].m_level;
				break;
			}
		}
		
		int cost = level + mastery.m_baseCost - 1;
		return (cost + 1) * (cost + 1) - cost * cost;
	}

	bool WeaponMasterySkillUp(WeaponMastery@ mastery)
	{
		if (mastery is null)
		{
			print("Can't find weapon mastery");
			return false;
		}
		
		int cost = GetMasteryWeaponCost(mastery);
		int freeSkillPts = GetFreeSkillPoints();
		if (freeSkillPts < cost)
		{
			print("Can't afford weapon mastery skill up");
			return false;
		}
		
		for (uint i = 0; i < weaponMasteries.length(); i++)
		{
			if (weaponMasteries[i].m_mastery is mastery)
			{
				weaponMasteries[i].m_level += 1;
				return true;
			}
		}
		
		WeaponMasteryLevel mod;
		@mod.m_mastery = mastery;
		mod.m_level = 1;
		weaponMasteries.insertLast(mod);
		return true;
	}

	bool SkillUp(const string& in id, bool comboSkill = false)
	{
		auto@ skillDef = playerClass.GetSkillDef(HashString(id));
		if (skillDef is null)
		{
			print("Invalid skill");
			return false;
		}
		
		int currLevel = 0;
		if (comboSkill)
		{
			if (!pickedComboSkills.get(id, currLevel))
				currLevel = 0;
		}
		else
		{
			if (!pickedSkills.get(id, currLevel))
				currLevel = 0;
		}
		
		if (uint(skillDef.m_startingLevel + currLevel) >= skillDef.m_levelParams.length())
		{
			print("Skill is max level");
			return false;
		}
		
		int freeSkillPts = GetFreeSkillPoints();
		if (comboSkill)
		{
			for (uint i = 0; i < skillDef.m_blockerSkills.length(); i++)
			{
				int lvl;
				if (!pickedComboSkills.get(skillDef.m_blockerSkills[i], lvl))
					continue;
				
				if (lvl == 0)
					continue;
				
				auto@ blockerDef = PlayerSkillDef::Get(skillDef.m_blockerSkills[i]);
				if (blockerDef is null)
					continue;
				
				lvl += blockerDef.m_startingLevel;
				for (int j = blockerDef.m_startingLevel; j < lvl; j++)
					freeSkillPts += blockerDef.m_levelSkillCost[j];
			}
		}
		
		int skillCost = skillDef.m_levelSkillCost[skillDef.m_startingLevel + currLevel];
		if (freeSkillPts < skillCost && skillCost > 0)
		{
			print("Can't afford skill");
			return false;
		}
		
		if (comboSkill)
		{
			for (uint i = 0; i < skillDef.m_blockerSkills.length(); i++)
				pickedComboSkills.set(skillDef.m_blockerSkills[i], 0);
			
			pickedComboSkills.set(id, currLevel + 1);
		}
		else
			pickedSkills.set(id, currLevel + 1);
		
		(Network::Message("PlayerSyncSkillLevel") << skillDef.m_idHash << (currLevel + 1) << comboSkill).SendToAll();
		
		SyncStatPoints();
		
		if (actor !is null)
		{
			cast<PlayerBase>(actor).LoadSkills();
			RefreshModifiers();
		}
		
		return true;
	}

	bool SkillTempUp(PlayerSkillDef@ skillDef)
	{
		if (skillDef is null)
			return false;
		
		int currLevel = 0;
		if (!pickedTempSkills.get(skillDef.m_id, currLevel))
			currLevel = 0;
		
		if (uint(skillDef.m_startingLevel + currLevel) >= skillDef.m_levelParams.length())
			return false;
		
		LootLog::PresentSkillSphere(this, skillDef, GetSkillLevel(skillDef));
		pickedTempSkills.set(skillDef.m_id, currLevel + 1);
		(Network::Message("PlayerSyncSkillTempLevel") << skillDef.m_idHash << (currLevel + 1)).SendToAll();
		
		
		SyncStatPoints();
		
		if (actor !is null)
		{
			cast<PlayerBase>(actor).LoadSkills();
			RefreshModifiers();
		}
		
		return true;
	}

	bool SkillTempDown(PlayerSkillDef@ skillDef)
	{
		if (skillDef is null)
			return false;
		
		int currLevel = 0;
		if (!pickedTempSkills.get(skillDef.m_id, currLevel))
			currLevel = 0;
		
		if (currLevel <= 0)
			return false;
		
		pickedTempSkills.set(skillDef.m_id, currLevel - 1);
		(Network::Message("PlayerSyncSkillTempLevel") << skillDef.m_idHash << (currLevel - 1)).SendToAll();
		
		SyncStatPoints();
		
		if (actor !is null)
		{
			cast<PlayerBase>(actor).LoadSkills();
			RefreshModifiers();
		}
		
		return true;
	}

	int GetPlaceableStatPoints()
	{
		int num = (level - 1) * Tweak::StatsPerLevel + bonusStatPts;
		if (local && g_myTownRecord !is null && g_myTownRecord.m_accomplishmentRewards !is null)
			num += g_myTownRecord.m_accomplishmentRewards.m_rAttribpt;
		
		return num - pickedStr - pickedDex - pickedInt - pickedFoc - pickedVit;
	}

	bool RefillPotionCharges(int charges = -1)
	{
		if (charges == 0)
			return false;
		
		bool refilled = potionChargesUsed > 0;
		
		if (charges < 0)
			potionChargesUsed = 0;
		else
			potionChargesUsed = max(0, potionChargesUsed - charges);
		
		auto player = cast<PlayerBase>(actor);
		if (player !is null)
			player.OnPotionCharged();

		return refilled;
	}
	
	Modifiers::ModifierList@ GetModifiers()
	{
		return modifiers.GetModifierList();
	}
	
	void TriggerModifierEffects(Modifiers::EffectTrigger trigger, Actor@ enemy = null, Skills::Skill@ skill = null)
	{
		modifiers.TriggerEffects(trigger, actor, enemy, skill);
	}

	void TriggerModifierQuantityEffects(Modifiers::QuantityTrigger trigger, int value, uint id = 0, Actor@ enemy = null, Skills::Skill@ skill = null)
	{
		modifiers.TriggerQuantityEffects(trigger, actor, value, id, enemy, skill);
	}

	void SetShopUpgradeLevel(uint shopId, uint upgrId, int level)
	{
		for (uint i = 0; i < shopUpgrades.length(); i++)
		{
			if (shopUpgrades[i].shopId == shopId && shopUpgrades[i].upgrId == upgrId)
			{
				shopUpgrades[i].level = level;
				if (level < 0)
					shopUpgrades.removeAt(i);
				
				return;
			}
		}
		
		if (level < 0)
			return;
		
		auto lvl = ShopUpgradeLevel(shopId, upgrId, level);
		if (lvl.upgrade !is null)
			shopUpgrades.insertLast(lvl);
	}

	int GetShopUpgradeLevel(uint shopId, uint upgrId)
	{
		for (uint i = 0; i < shopUpgrades.length(); i++)
			if (shopUpgrades[i].shopId == shopId && shopUpgrades[i].upgrId == upgrId)
				return shopUpgrades[i].level;
		
		return -1;
	}

	void RefreshModifiers()
	{
		%PROFILE_SCOPE PlayerRecord::RefreshModifiers
		
		modifiers.m_suppressSort = true;
		modifiers.Clear();

		for (uint i = 0; i < shopUpgrades.length(); i++)
			modifiers.AddModifiers(shopUpgrades[i].upgrade.m_steps[shopUpgrades[i].level].m_modifiers, 1.0f, shopUpgrades[i].upgrade.m_steps[shopUpgrades[i].level]);

		for (uint i = 0; i < g_myTownRecord.m_heroTitles.length(); i++)
			modifiers.AddModifiers(g_myTownRecord.m_heroTitles[i].m_title.m_modifiers, float(g_myTownRecord.m_heroTitles[i].m_level) / 10.0f, g_myTownRecord.m_heroTitles[i]);

		for (uint i = 0; i < g_myTownRecord.m_donationTitles.length(); i++)
			modifiers.AddModifiers(g_myTownRecord.m_donationTitles[i].m_title.m_modifiers, float(g_myTownRecord.m_donationTitles[i].m_level) / 10.0f, g_myTownRecord.m_donationTitles[i]);

		for (uint i = 0; i < g_currTownRecord.m_buildings.length(); i++)
		{
			auto@ building = g_currTownRecord.m_buildings[i];
			auto@ variations = building.buildingDef.m_variations;
			
			if (building.variation >= variations.length())
				continue;
			
			auto@ mods = variations[building.variation].m_modifiers;
			if (mods !is null && mods.length() > 0)
				modifiers.AddModifiers(mods, 1.0f, variations[building.variation]);
		}

		for (uint i = 0; i < missionBuffs.length(); i++)
			modifiers.AddModifiers(missionBuffs[i].m_buff.m_modifiers, 1.0f, missionBuffs[i].m_buff);

		for (uint i = 0; i < g_players.length(); i++)
		{
			if (g_players[i].peer != 0)
				continue;
			
			auto@ archBuffs = g_players[i].architectBuffs;
			for (uint j = 0; j < archBuffs.length(); j++)
				modifiers.AddModifiers(archBuffs[j].m_modifiers, 1.0f, archBuffs[j]);
			break;
		}

		auto missionGM = cast<MissionGameModeBase>(g_gameMode);
		if (missionGM !is null && missionGM.m_missionLevel !is null && missionGM.m_missionLevel.m_plrModifiers !is null)
			modifiers.AddModifiers(missionGM.m_missionLevel.m_plrModifiers, 1.0f, missionGM.m_missionLevel);


		auto weaponMasteriesModProv = ModifierProvider(Resources::GetString(".menu.player.mods.stats.source.weapon_mastery"));
		for (uint i = 0; i < weaponMasteries.length(); i++)
			modifiers.AddModifiers(weaponMasteries[i].m_mastery.m_modifiers, float(weaponMasteries[i].m_level), weaponMasteriesModProv);


		array<Item::TrinketSet@> sets;
		for (uint i = 0; i < trinketInventory.m_items.length(); i++)
		{
			modifiers.AddModifiers(trinketInventory.m_items[i].GetModifiers(this), 1.0f, trinketInventory.m_items[i]);
			
			auto set = trinketInventory.m_items[i].m_set;
			if (set !is null)
			{
				set.m_tmpCounter++;
				sets.insertLast(set);
			}
		}
		
		for (uint i = 0; i < sets.length(); i++)
		{
			if (sets[i].m_tmpCounter == 0)
				continue;
			
			auto mod = sets[i].GetModifiers(sets[i].m_tmpCounter);
			if (mod !is null)
				modifiers.AddModifiers(mod, 1.0f, sets[i]);
			
			sets[i].m_tmpCounter = 0;
		}

		auto player = cast<PlayerBase>(actor);
		if (player !is null)
		{
			// Add modifiers
			auto@ buffs = player.m_buffs.m_buffs;
			for (uint i = 0; i < buffs.length(); i++)
				if (buffs[i].m_def.m_modifiers.length() > 0)
					modifiers.AddModifiers(buffs[i].m_def.m_modifiers, buffs[i].m_intensity, buffs[i].m_def);
			
			auto@ stacks = player.m_buffs.m_stacks;
			for (uint i = 0; i < stacks.length(); i++)
			{
				if (stacks[i].m_def.m_buffDef !is null && stacks[i].m_def.m_buffDef.m_modifiers.length() > 0)
					modifiers.AddModifiers(stacks[i].m_def.m_buffDef.m_modifiers, stacks[i].GetIntensity(), stacks[i].m_def.m_buffDef);
			}
			
			for (uint i = 0; i < player.m_skills.length(); i++)
			{
				auto mods = player.m_skills[i].GetModifiers();
				if (mods !is null && mods.length() > 0)
					modifiers.AddModifiers(mods, 1.0f, player.m_skills[i]);
			}
			
			// Add dynamic modifiers
			auto@ modList = modifiers.GetModifierList();
			for (uint i = 0; i < stacks.length(); i++)
			{
				auto mods = modList.DynamicStackModifiers(player, stacks[i].m_def);
				if (mods !is null && mods.length() > 0)
					modifiers.AddModifiers(mods, stacks[i].GetIntensity(), stacks[i].m_def);
			}
			
			for (uint i = 0; i < modStacks.length(); i++)
				modStacks[i].Reset(modStacks[i].m_def);
			
			modList.ModifyStacks(player);
		}



		array<Equipment::Equipment@> toEquip;
		for (uint i = 0; i < equipped.m_items.length(); i++)
		{
			if (equipped.m_items[i] !is null)
				toEquip.insertLast(equipped.m_items[i]);
		}

		Hooks::Call("PlayerRecordRefreshModifiers", @this);

		while (toEquip.length() > 0)
		{
			modifiers.SortModifiers();
			RefreshStats();
			
			int numNewUsed = 0;
			for (uint i = 0; i < toEquip.length(); )
			{
				auto item = toEquip[i];
				if (!equipped.MayEquip(item))
				{
					i++;
					continue;
				}
				
				modifiers.AddModifiers(item.GetModifiers(), item.GetModifierIntensity(), item, true);
				toEquip.removeAt(i);
				numNewUsed++;
			}
			
			if (numNewUsed <= 0)
				break;
		}

		modifiers.m_suppressSort = false;
		modifiers.SortModifiers();
		RefreshStats();
	}
	
	ActorBuffStackDefModified@ GetModifiedStack(ActorBuffStackDef@ def, bool create)
	{
		for (uint i = 0; i < modStacks.length(); i++)
			if (modStacks[i].m_def is def)
				return modStacks[i];
		
		if (create)
		{
			auto modStack = ActorBuffStackDefModified(def);
			modStacks.insertLast(modStack);
			return modStack;
		}
		
		return null; 
	}
	
	void OnEventPlayerCollectedItem(PlayerRecord@ player, Item::Item@ item, const bool &in showAnnounce, const int &in amount)
	{ 
		if (player !is this && player !is null)
			return;

		if (local && showAnnounce)
		{
			uint qualityFilter = 0;
			qualityFilter |= Item::Quality::Epic;
			qualityFilter |= Item::Quality::Legendary;
			qualityFilter |= Item::Quality::Unique;

			if ((item.GetQuality() & qualityFilter) != 0 )
				PlayVoice("find_rare_item");
		}

		if (item.GetSkill() is null || item.IsEquippable())
			return;
		
		auto plr = cast<PlayerBase>(actor);
		if (plr !is null)
			plr.LoadSkills();
	}
	
	void OnEventPlayerLostItem(PlayerRecord@ player, Item::Item@ item)
	{ 
		if (player !is this && player !is null)
			return;
		if (item.GetSkill() is null || item.IsEquippable())
			return;

		auto plr = cast<PlayerBase>(actor);
		if (plr !is null)
			plr.LoadSkills();
	}
	
	void RefreshStats()
	{
		%PROFILE_SCOPE BuildStats
		modifiers.BuildStats(this, currStats);
	}

	void AssignUnit(UnitPtr unit)
	{
		@actor = cast<Actor>(unit.GetScriptBehavior());
		deadTime = 0;
	}

	int MaxHealth() { return currStats.Health; }
	int MaxMana() { return currStats.Mana; }


	void ResetForNewMission()
	{
		ResetStatsRun();
		ResetPlayerHealthMana();
		ResetSkillTempLevels();
		ResetBuffs();
		potionChargesUsed = 0;
		rerollsUsed = 0;
		shadowCurses = 0;
		lockedHp = 0;
		soulLinked.removeRange(0, soulLinked.length());
		trinketInventory.Clear();
		valuableInventory.Clear();
		ClearAllMissionBuffs();
		ClearSummons();
	}


	float ScaleShadowCurse(float curses)
	{
		float mul = GetModifiers().ShadowCurseGainMul(this) + g_ngp * Tweak::NGPShadowCurseGain;
		if (g_ngp > 1.5f)
			mul += Tweak::NGPShadowCurseFlatGain;
		return curses * mul;
	}
	
	int GiveShadowCurse(Actor@ curser, float curses, bool skipGainMod = false)
	{
		if (CinemaManager::g_cinematicC > 0)
			return 0;
		
		int numToGive = 0;
		if (!skipGainMod)
			numToGive = roll_round(ScaleShadowCurse(curses));
		else
			numToGive = int(curses);
		
		if (numToGive > 0 && curser !is null && curser is lastCurser && g_ngp < 1.5f)
		{
			auto bossTag = g_actorTags.GetTag("boss");
			if (!(curser.Tags & bossTag != 0))
				return 0;
		}
		
		if (HasMissionBuff("tavern_drink_stinging_curse"))
		{
			int numAbsorbed = 0;
			for (int i = 0; i < numToGive; i++)
			{
				if (randf() < Tweak::TavernDrinkStingingCurseAbsorbChance)
					numAbsorbed++;
			}
			
			numToGive -= numAbsorbed;
			
			if (numAbsorbed > 0 && actor !is null)
			{
				DamageInfo dmg;
				dmg.TrueStrike = true;
				dmg.PureDamage = numAbsorbed * Tweak::TavernDrinkStingingCurseAbsorbDmg;
				actor.Damage(dmg, xy(actor.m_unit.GetPosition()), vec2(0, 0));
			}
		}
		
		int preNum = shadowCurses;
		shadowCurses = clamp(shadowCurses + numToGive, 0, 100);
		int numChanged = shadowCurses - preNum;
		
		if (numChanged != 0)
			LootLog::PresentPickup(this, LootLog::g_lootStrShadowCurse, numChanged);
		
		if (numChanged > 0)
		{
			%STAT Add shadow-curse-got numChanged this
			@lastCurser = curser;
		}
		
		return numChanged;
	}

	int64 LevelExperience(int atLevel)
	{
		return int64(Tweak::ExperiencePerLevel * pow(atLevel, Tweak::ExperienceExponent));
	}

	void NetSyncExperience(int lvl, int exp)
	{
		level = lvl;
		experience = exp;
	}

	bool CanAddItem(Item::Item@ item)
	{
		auto equip = cast<Equipment::Equipment>(item);
		if (equip !is null && !equipInventory.CanAdd())
		{
			PlayVoice("cant");
			return false;
		}
		
		return true;
	}

	bool justGotEquipment;
	void GiveItem(Item::Item@ item)
	{
		auto equip = cast<Equipment::Equipment>(item);
		if (equip !is null)
		{
			justGotEquipment = true;
			equipInventory.Add(equip);
			LootLog::PresentEquipment(this, equip);
			return;
		}
		
		auto trinket = cast<Item::Trinket>(item);
		if (trinket !is null)
		{
			justGotEquipment = false;
			trinket.m_seen = true;
			trinketInventory.Add(trinket);
			LootLog::PresentTrinket(this, trinket);
			RefreshModifiers();
			g_myTownRecord.statsTown.StatAdd(HashString("trinket-found-" + trinket.m_id), 1);
			Stats::Add(HashString("collected-trinket-" + Item::QualityToString(trinket.m_quality)), 1, this);
			return;
		}
		
		auto valuable = cast<Item::Valuable>(item);
		if (valuable !is null)
		{
			auto given = GiveMaterial(MaterialType::Gold, valuable.GetPrice());
			valuableInventory.AddItem(valuable, given);
			LootLog::PresentMaterial(this, MaterialType::Gold, given);
			
			%STAT Add valuables-collected 1 this
			%STAT Add valuables-value given this
			
			return;
		}
		
		auto cItem = cast<Item::IConsumableItem>(item);
		if (cItem !is null)
		{
			cItem.ConsumeItem(this);
			return;
		}
	}

	void SetMissionBuff(uint32 id, MissionBuff@ buff)
	{
		for (uint i = 0; i < missionBuffs.length(); i++)
		{
			if (missionBuffs[i].m_id == id)
			{
				@missionBuffs[i].m_buff = buff;
				RefreshModifiers();
				return;
			}
		}
		
		AppliedMissionBuff mbuff;
		mbuff.m_id = id;
		@mbuff.m_buff = buff;
		
		missionBuffs.insertLast(mbuff);
		RefreshModifiers();
	}

	bool HasMissionBuff(const string &in buffId)
	{
		auto buffIdHash = HashString(buffId);
		
		for (uint i = 0; i < missionBuffs.length(); i++)
		{
			if (missionBuffs[i].m_buff.m_idHash == buffIdHash)
				return true;
		}
		
		for (uint i = 0; i < g_players.length(); i++)
		{
			if (g_players[i].peer != 0)
				continue;
			
			auto@ archBuffs = g_players[i].architectBuffs;
			for (uint j = 0; j < archBuffs.length(); j++)
				if (archBuffs[j].m_idHash == buffIdHash)
					return true;
			break;
		}
		
		return false;
	}

	bool HasMissionBuff(MissionBuff@ buff)
	{
		for (uint i = 0; i < missionBuffs.length(); i++)
		{
			if (missionBuffs[i].m_buff is buff)
				return true;
		}
		
		for (uint i = 0; i < g_players.length(); i++)
		{
			if (g_players[i].peer != 0)
				continue;
			
			auto@ archBuffs = g_players[i].architectBuffs;
			for (uint j = 0; j < archBuffs.length(); j++)
				if (archBuffs[j] is buff)
					return true;
			break;
		}
		
		return false;
	}

	bool HasMissionBuff(uint32 id)
	{
		for (uint i = 0; i < missionBuffs.length(); i++)
		{
			if (missionBuffs[i].m_id == id)
				return true;
		}
		return false;
	}

	bool HasMissionBuff(uint32 id, MissionBuff@ buff)
	{
		for (uint i = 0; i < missionBuffs.length(); i++)
		{
			if (missionBuffs[i].m_id == id && missionBuffs[i].m_buff is buff)
				return true;
		}
		return false;
	}

	void ClearAllMissionBuffs()
	{
		missionBuffs.removeRange(0, missionBuffs.length());
		architectBuffs.removeRange(0, architectBuffs.length());
	}

	void CheckForLevelup()
	{
		if (playerClass is null)
			return;
		
		int baseExp = 0;
		
		if (local && g_myTownRecord !is null && g_myTownRecord.m_accomplishmentRewards !is null)
			baseExp = g_myTownRecord.m_accomplishmentRewards.m_rExp;
		
		if ((baseExp + experience) >= LevelExperience(level))
		{
			experience -= 1;
			GiveExperience(1, true);
		}
	}

	int GetLevelCap()
	{
		return int(Tweak::LevelCap + float(ngp) * Tweak::LevelCapNGPAdd + 0.5f);
	}

	int GetEquipmentDropLevelCap()
	{
		return max(GetLevelCap() + 5, level + 10);
	}

	int GiveExperience(int amount, bool skipGainMod = false)
	{
		if (amount <= 0)
			return 0;

		float xpMul = 1.0f;
		if (!skipGainMod)
		{
			if (actor !is null)
			{
				auto pb = cast<PlayerBase>(actor);
				if (pb !is null)
					xpMul *= pb.m_buffs.ExperienceMul();
			}
			
			xpMul *= currStats.ExperienceMul * Tweak::ExperienceScale * g_mpExpScale;
			xpMul *= GetLevelDifferenceExperienceMul(float(level), g_diffLevel);
		}

		amount = roll_round(amount * xpMul);

		int xpNeeded = 0;
		int xpAdded = amount;
		int levelsAdded = 0;

		%STAT Add exp-gained amount this
		LootLog::PresentPickup(this, LootLog::g_lootStrExperience, amount);

		int prevStatPoints = GetPlaceableStatPoints();
		int prevSkillPoints = GetFreeSkillPoints();

		//int lvlCap = int(Tweak::LevelCap + min(float(ngp), g_ngp) * Tweak::LevelCapNGPAdd + 0.5f);
		int lvlCap = GetLevelCap();
%if DEMO_BUILD
		lvlCap = 10;
%endif

		int baseExp = 0;
		if (local && g_myTownRecord !is null && g_myTownRecord.m_accomplishmentRewards !is null)
			baseExp = g_myTownRecord.m_accomplishmentRewards.m_rExp;

		while (true)
		{
			if (level >= lvlCap)
				break;
			
			xpNeeded = LevelExperience(level);
			
			if ((baseExp + experience) + xpAdded >= xpNeeded)
			{
				int add = xpNeeded - (baseExp + experience);
				experience += add;
				xpAdded -= add;
				
				level++;
				levelsAdded++;
			}
			else
			{
				experience += xpAdded;
				break;
			}
		}

		if (local)
		{
			if (levelsAdded > 0)
			{
				Tutorials::ShowTutorial("levelup");
				if (actor !is null)
				{
					int currStatPoints = GetPlaceableStatPoints() - prevStatPoints;
					int currSkillPoints = GetFreeSkillPoints() - prevSkillPoints;
					
					cast<Player>(actor).OnLevelUp(levelsAdded, currStatPoints, currSkillPoints);
					
					ResetPlayerHealthMana();
					//RefillPotionCharges();
				}
				
				%STAT Add levels-gained levelsAdded this
				if (playerClass !is null)
				{
					if (playerClass.parent != 0)
					{
						auto parent = PlayerClass::Get(playerClass.parent);
						Stats::Max(HashString("max-level-" + parent.m_id), level);
					}
					else
						Stats::Max(HashString("max-level-" + playerClass.m_id), level);
				}
				
				g_myTownRecord.RefreshHeroTitles();
				
				Hooks::Call("LevelupCharacter", @this);
				
				RefreshModifiers();
			}
			
			(Network::Message("PlayerSyncExperience") << level << experience).SendToAll();
		}

		return amount;
	}

	void PlayVoice(const string &in line, bool usePosition = false)
	{
		if (playerVoice is null)
			return;

		auto sound = playerVoice.GetVoiceLine(line);
		if (sound is null)
			return;

		if (actor is null)
			return;

		if (usePosition)
			PlaySound3D(sound, actor.m_unit.GetPosition());
		else
			PlaySound3D(sound, actor.m_unit);
		
	}

	void PlayVoice(const string &in line, dictionary params, bool usePosition = false)
	{
		if (playerVoice is null)
			return;

		auto sound = playerVoice.GetVoiceLine(line);
		if (sound is null)
			return;

		if (actor is null)
			return;

		if (usePosition)
			PlaySound3D(sound, actor.m_unit.GetPosition(), params);
		else
			PlaySound3D(sound, actor.m_unit, params);
		
	}

	float GetMaterialModifier(MaterialType type) 
	{
		//if (type == MaterialType::Ore)
		//	return GetModifiers().MaterialGainMul(this, type) * GetModifiers().MaterialGainMulMul(this, type);
		return (GetModifiers().MaterialGainMul(this, type) + g_ngp * Tweak::NGPMaterialGain) * GetModifiers().MaterialGainMulMul(this, type);
	}

	int GiveMaterial(MaterialType type, int amount, bool skipGainMod = false)
	{
		if (amount == 0)
			return 0;

		if (cast<TownGameMode>(g_gameMode) is null)
		{
			float mul = skipGainMod ? 1.0f : GetMaterialModifier(type);

			int preMaterial = materials[int(type)];
			materials[int(type)] = max(0, materials[int(type)] + roll_round(amount * mul));

			GameEvents::PlayerMaterialChanged(this, type);
			int given = materials[int(type)] - preMaterial;

			if (given > 0)
			{
				switch (MaterialType(type))
				{
				case MaterialType::Gold:
					%STAT Add collected-gold given this
					break;
				case MaterialType::Wood:
					%STAT Add collected-wood given this
					break;
				case MaterialType::Stone:
					%STAT Add collected-stone given this
					break;
				case MaterialType::Iron:
					%STAT Add collected-iron given this
					break;
				case MaterialType::Crystals:
					%STAT Add collected-crystals given this
					break;
				case MaterialType::Dust:
					%STAT Add collected-dust given this
					break;
				case MaterialType::Ore:
					%STAT Add collected-ore given this
					break;
				}
			}

			return given;
		}
		else
			return g_myTownRecord.GiveMaterial(type, amount);
	}

	int GetMaterial(MaterialType type)
	{
		if (cast<TownGameMode>(g_gameMode) is null)
			return materials[int(type)];
		else
			return g_myTownRecord.GetMaterial(type);
	}

	string GetLobbyName()
	{
		return Lobby::GetPlayerName(peer);
	}

	string GetName()
	{
		/*if (Platform::GetSessionCount() == 1)
			return Lobby::GetPlayerName(peer);

		return "player " + (peer + 1);*/
		return name;
	}

	int GetPing() { return Lobby::GetPlayerPing(peer); }

	bool IsDead()
	{
		return deadTime > 0 && actor is null;
	}

	int CurrentHealth()
	{
		return int(ceil(hp * MaxHealth()));
	}

	int CurrentMana()
	{
		return int(floor(mana * MaxMana()));
	}

	bool HasBeenDeadFor(uint ms)
	{
		if (!IsDead())
			return false;

		return (deadTime + ms) < g_scene.GetTime();
	}

	int opCmp(const PlayerRecord &in other)
	{
		if (peer < other.peer) return -1;
		else if (peer > other.peer) return 1;
		return 0;
	}
	


	int GetAvailableSkillpoints() { return 0; }

  void SyncShopUpgradesWithOtherCharacters()
  {
    if (g_isSyncingSharedUpgrades)
      return;
    
    g_isSyncingSharedUpgrades = true;
    auto characters = PersistentSaves::GetCharacterList();
    dictionary highestUpgrades;
    
    for (uint i = 0; i < characters.length(); i++)
    {
      if (characters[i] == 0 || characters[i] == uniqueKey)
        continue;
      
      auto plrData = PersistentSaves::GetCharacter(characters[i]);
      if (plrData is null)
        continue;
      
      PlayerRecord tempRecord;
      tempRecord.Load(plrData, StartMode::StartGame);
                
      for (uint j = 0; j < tempRecord.shopUpgrades.length(); j++)
      {
        auto upgrade = tempRecord.shopUpgrades[j];
        string key = upgrade.shopId + "_" + upgrade.upgrId;
        
        int currentHighest = -1;
        if (highestUpgrades.exists(key))
          highestUpgrades.get(key, currentHighest);
        else
          highestUpgrades.set(key, -1);
        
        string upgradeName = (upgrade.upgrade !is null) ? upgrade.upgrade.m_id : "<unknown>";
        
        if (upgrade.level > currentHighest)
          highestUpgrades.set(key, upgrade.level);
      }
    }
    
    array<string> keys = highestUpgrades.getKeys();
    bool upgradesChanged = false;
        
    for (uint i = 0; i < keys.length(); i++)
    {
      string[] parts = keys[i].split("_");
      if (parts.length() != 2)
        continue;
          
      uint shopId = parseInt(parts[0]);
      uint upgradeId = parseInt(parts[1]);
      
      int highestLevel = 0;
      highestUpgrades.get(keys[i], highestLevel);
      
      int currentLevel = GetShopUpgradeLevel(shopId, upgradeId);
      
      if (highestLevel > currentLevel)
      {
        SetShopUpgradeLevel(shopId, upgradeId, highestLevel);
        upgradesChanged = true;
      }
    }
    
    if (upgradesChanged)
      RefreshModifiers();
    
    g_isSyncingSharedUpgrades = false;
  }
}

float GetLevelDifferenceExperienceMul(float plrLvl, float diffLvl)
{
	if (abs(diffLvl) > 0.1f)
	{
		/*
		const float loBnd = -10;
		const float hiBnd = 5;
		const float ptPen = 0.15f;
		float lvlDiff = plrLvl - diffLvl;
		
		return clamp(1.0f + min(min(lvlDiff - loBnd, hiBnd - lvlDiff), 0) * ptPen, 0.1f, 1.0f);
		*/
		
		float lvlDiff = plrLvl - diffLvl;
		
		if (plrLvl < diffLvl)
		{
			float loBnd = -(10 + plrLvl);
			float ptPen = 0.15f / max(1.0f, diffLvl / 25.0f);
			
			return clamp(1.0f + min(lvlDiff - loBnd, 0) * ptPen, 0.25f, 1.0f);
		}
		else
		{
			const float hiBnd = 5;
			const float ptPen = 0.15f;
			
			return clamp(1.0f + min(hiBnd - lvlDiff, 0) * ptPen, 0.1f, 1.0f);
		}
	}
	
	return 1;
}

void DemoExpFormula()
{
	array<int> lvls = { 1, 3, 5, 10, 15, 20, 30, 40, 50, 75, 100, 125, 150, 200, 250, 300 };
	
	for (uint a = 0; a < lvls.length(); a++)
	{
		string str = "";
		int prev = -100;
		bool found = false;
		for (uint b = 0; b < lvls.length(); b++)
		{
			int pct = int(GetLevelDifferenceExperienceMul(lvls[a], lvls[b]) * 100);
			/*
			if (b > 0)
			{
				if (prev == pct)
				{
					if (found && pct < 100)
						break;
					else
						str = "";
				}
				else if (pct == 100)
					found = true;
			}
			*/
			str += lvls[b] + ": " + pct + "%; ";
			prev = pct;
		}
		
		print("Exp gain for plr lvl " + lvls[a] + " playing content lvl: " + str);
	}



}