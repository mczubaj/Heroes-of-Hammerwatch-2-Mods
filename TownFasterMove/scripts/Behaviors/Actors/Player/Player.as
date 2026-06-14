array<UnitProducer@> infiniteSummons = {
	Resources::GetUnitProducer("players/shared/units/mercenary_pikeman.unit"),
	Resources::GetUnitProducer("players/shared/units/mercenary_crossbowman.unit"),
	
	Resources::GetUnitProducer("players/shared/units/mercenary_archon_punisher.unit"),
	Resources::GetUnitProducer("players/shared/units/mercenary_archon_sniper.unit"),
	Resources::GetUnitProducer("players/shared/units/mercenary_archon_wizard.unit")
};

uint g_hashed_phoenix_feather = HashString("phoenix_feather");



class Player : PlayerBase, IPreRenderable
{
	array<PlayerUsable@> m_usables;

	vec2 m_lastDirection;
	vec2 m_lastSentPos;
	vec2 m_lastSentDir;
	vec2 m_lastSentStats;

	int m_dashRechargeC;
	int m_potionDelay;

	PathFollower m_cinemaPathFollower;

	UnitScene@ m_fxBlockProjectile;
	SoundEvent@ m_sndBlockProjectile; // TODO: Just move this sound to the effect??
	UnitScene@ m_fxBlockPhysical;
	UnitScene@ m_fxBlockMagical;

	SoundEvent@ m_sndNoMana;
	SoundEvent@ m_sndCooldown;
	SoundEvent@ m_evadeSound;

	bool m_returningDamage;
	int m_forceSendMoveC;

	PlayerTargetingHelper@ m_targetHelper;

	vec2 m_prevDir;
	bool m_usingController;

	int m_healthRegenC;
	int m_shadeSpawnC;

	bool m_gentleTraps;


	Player(UnitPtr unit, SValue& params)
	{
		super(unit, params);

		@m_fxBlockProjectile = Resources::GetEffect("effects/players/block_projectile.effect");
		@m_sndBlockProjectile = Resources::GetSoundEvent("event:/sfx/character/player/projectile_block");
		@m_fxBlockPhysical = Resources::GetEffect("effects/players/block_physical.effect");
		@m_fxBlockMagical = Resources::GetEffect("effects/players/block_magical.effect");

		@m_sndNoMana = Resources::GetSoundEvent("event:/sfx/player/no_mana");
		@m_sndCooldown = Resources::GetSoundEvent("event:/sfx/player/cooldown");
		@m_evadeSound = Resources::GetSoundEvent("event:/sfx/player/dodge");

		m_returningDamage = false;

		@m_targetHelper = PlayerTargetingHelper(this);
		m_cinemaPathFollower.Initialize(unit, 0, false, 0);
		m_cinemaPathFollower.m_host = true;

		auto gm = cast<HWR2GameMode>(g_gameMode);
		m_gentleTraps = (gm !is null && gm.HasArchitectBuff("architect_gentle_traps"));

		m_shadeSpawnC = 20000;
	}

	void Initialize(PlayerRecord@ record) override
	{
		PlayerBase::Initialize(record);

		m_preRenderables.insertLast(this);

		m_unit.SetShouldCollide(!GetVarBool("cht_noclip"));
		m_unit.SetHidden(GetVarBool("cht_plr_hidden"));
		
		vec2 pos = xy(m_unit.GetPosition());
		for (uint i = 0; i < record.summons.length(); i++)
		{
			auto@ summ = record.summons[i];
			if (summ.m_prod is null)
				continue;
			
			bool remote = (!Network::IsServer() && IsNetsyncedExistance(summ.m_prod.GetNetSyncMode()));
			auto@ units = summ.m_units;
			for (uint j = 0; j < units.length(); j++)
			{
				if (units[j] !is null)
					continue;
				
				if (remote)
					(Network::Message("SpawnPlayerSummon") << summ.m_prod.GetResourceHash() << pos << summ.m_saveData[j].Copy()).SendToHost();
				else
				{
					auto unit = summ.m_prod.Produce(g_scene, xyz(pos));
					auto ownedUnit = cast<IOwnedUnit>(unit.GetScriptBehavior());
					if (ownedUnit !is null)
						ownedUnit.LoadUnit(summ.m_saveData[j]);
				}
				
				units.removeAt(j);
				summ.m_weaponInfo.removeAt(j);
				summ.m_save.removeAt(j);
				summ.m_saveData.removeAt(j);
				j--;
			}
		}
		
		record.CheckForLevelup();
	}
	
	int FindUsable(IUsable@ usable)
	{
		for (uint i = 0; i < m_usables.length(); i++)
		{
			if (m_usables[i].m_usable is usable)
				return i;
		}
		return -1;
	}

	void AddUsable(IUsable@ usable)
	{
		int index = FindUsable(usable);
		if (index != -1)
		{
			m_usables[index].m_refCount++;
			return;
		}

		m_usables.insertLast(PlayerUsable(usable));
		m_usables.sortAsc();
	}

	void RemoveUsable(IUsable@ usable)
	{
		int index = FindUsable(usable);
		if (index != -1)
		{
			if (--m_usables[index].m_refCount <= 0)
				m_usables.removeAt(index);
			return;
		}
	}

	IUsable@ GetTopUsable()
	{
		for (uint i = 0; i < m_usables.length(); i++)
		{
			if (m_usables[i].m_usable.CanUse(this))
				return m_usables[i].m_usable;
		}
		if (m_usables.length() > 0)
			return m_usables[0].m_usable;
		return null;
	}

	bool IsHusk() override { return false; }


	int m_summonOwnerEventC;
	void SummonOwnerEvent(OwnerAggroEvent event, Actor@ other)
	{
		if (m_summonOwnerEventC > 0)
			return;
		
		m_summonOwnerEventC = 1000;
		uint numSummons = m_record.summons.length();
		for (uint i = 0; i < numSummons; i++)
		{
			auto@ units = m_record.summons[i].m_units;
			uint numUnits = units.length();
			for (uint j = 0; j < numUnits; j++)
				units[j].OwnerEvent(event, other);
		}
	}

	void DamagedActor(Actor@ actor, DamageInfo di) override
	{
		SummonOwnerEvent(OwnerAggroEvent::Damaged, actor);
		
		PlayerBase::DamagedActor(actor, di);
		
		if (di.Damage > 0)
		{
			if (!g_inTown)
			{
				%STAT Add damage-dealt di.Damage m_record
				%STAT Max damage-dealt-max di.Damage m_record
			}
			
			Hooks::Call("PlayerDamagedActor", @this, @actor, @di);
			
			if (di.Weapon != 0)
				Stats::Add(HashString("damage-dealt-" + di.Weapon), di.Damage, m_record);
		}
		
		if (di.Damage > 0 && m_returningDamage)
			%STAT Add damage-returned di.Damage m_record
	}

	void NetShareExperience(int experience, Actor@ killed)
	{
		int xpr = int(experience * m_record.GetModifiers().ExpMul(this, killed));
		if (xpr > 0)
			m_record.GiveExperience(xpr);
	}

	void PlayerKilled(PlayerRecord@ player)
	{
	}

	void KilledActor(Actor@ killed, DamageInfo di) override
	{
		PlayerBase::KilledActor(killed, di);
		
		auto weapon = GetSkill(di.Weapon);
		//auto enemy = cast<CompositeActorBehavior>(killed);
		m_record.TriggerModifierEffects(Modifiers::EffectTrigger::Kill, killed, weapon);
		m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::Kill, 1, 0, null, weapon);
		
		{
			int xp = killed.GetExperienceReward(m_record.level);
			if (xp > 0)
			{
				(Network::Message("PlayerShareExperience") << true << xp).SendToAll();
				NetShareExperience(xp, killed);
			}
			
			
			auto killedUnitStat = Console::Cheats::RegisterKill(killed.m_unit.GetUnitProducer());
			if (killedUnitStat !is null)
			{
				killedUnitStat.kills++;
				killedUnitStat.expGained += xp;
			}
			
			%STAT Add enemy-kills 1 m_record
		}

		if (m_record.local)
			m_record.PlayVoice("kill");
		
		GameEvents::PlayerKilledActor(this, killed);
		Hooks::Call("PlayerKilledActor", @this, @killed, @di);

		for (uint i = 0; i < Tweak::AchievementKillActorTags.length(); i++)
		{
			if ((killed.Tags & Tweak::AchievementKillActorTags[i]) == Tweak::AchievementKillActorTags[i])
				Stats::Add(Tweak::AchievementKillActorStat[i], 1, m_record);
		}
	}

	void Kill(Actor@ killer, uint weapon) override
	{
		OnDeath(DamageInfo(killer, weapon), m_lastDirection);
		Actor::Kill(killer, weapon);
	}
	
	%if NON_FINAL
	bool ApplyBuff(ActorBuff@ buff) override
	{
		if (buff is null || buff.m_def is null)
			return false;

		if (CVars::ChtGodmode && buff.m_def.m_debuff)
			return false;
		
		return PlayerBase::ApplyBuff(buff);
	}
	%endif

	void GiveMana(int amount, bool pickup = false) override
	{
		float gain = m_record.currStats.ManaGain;
		if (pickup)
			gain *= m_record.GetModifiers().PickupGainScale(this).y;
		
		int mana = int(amount * gain);
		AddFloatingGive(mana, FloatingTextType::PlayerMana);
		m_record.mana = clamp(m_record.mana + float(mana) / float(m_record.MaxMana()), 0.0f, 1.0f);

		if (mana > 0)
			m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::ManaGained, mana);
		else
			m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::ManaLost, mana);
	}

	void GiveDashCharges(int charges) override
	{
		//AddFloatingGive(charges, FloatingTextType::PlayerAmmo);
		m_record.dashCharges = clamp(m_record.dashCharges + charges, 0, m_record.currStats.MaxDashes);

		if (charges > 0)
			m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::DashChargeGained, charges);
		else
			m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::DashChargeSpent, charges);
	}

	int Heal(int amount, bool pickup = false) override
	{
		float gain = m_record.currStats.HealthGain;
		if (pickup)
			gain *= m_record.GetModifiers().PickupGainScale(this).x;
		
		int healAmnt = int(amount * gain);
		m_record.hp = min(1.f, m_record.hp + healAmnt / float(m_record.currStats.Health));

		AddFloatingGive(healAmnt, FloatingTextType::PlayerHealed);
		(Network::Message("PlayerHealed") << healAmnt << m_record.hp).SendToAll();

		if (!g_inTown)
			%STAT Add amount-healed healAmnt m_record

		if (healAmnt > 0)
			m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::HealthGained, healAmnt);
		else
			m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::HealthLost, healAmnt);

		return healAmnt;
	}
	
	bool Evade(Actor@ attacker) override
	{
		if (attacker !is null && attacker.Team == Team)
			return false;
		
		if (roll_chance(this, m_record.currStats.EvadeChance) || m_record.GetModifiers().Evasion(this, attacker))
		{
			if (!g_inTown)
				%STAT Add evade-amount 1 m_record
			
			m_record.TriggerModifierEffects(Modifiers::EffectTrigger::Evade, attacker);
			m_dmgColor = vec4(0, 0, 0, 2.0f);
			(Network::Message("PlayerEvaded")).SendToAll();
			AddFloatingEvaded();

			if (!m_evadeEffects.isEmpty())
			{
				vec2 dir = GetDirection();
				if (attacker !is null)
					dir = normalize(xy(attacker.m_unit.GetPosition() - m_unit.GetPosition()));
				
				ApplyEffects(m_evadeEffects, this, this.m_unit, xy(m_unit.GetPosition()), dir, 1.0f, false);
			}

			PlaySound3D(m_evadeSound, m_unit.GetPosition());

			return true;
		}
		
		return false;
	}
	
	
	int Damage(DamageInfo dmg, vec2 pos, vec2 dir) override
	{
		if (CVars::ChtGodmode)
			return 0;

		if (CinemaManager::g_cinematicC > 0)
			return 0;

		if (m_record.IsDead())
			return 0;

		if (g_gameMode.m_gameTime - m_spawnTime < Tweak::SpawnInvulnTime)
			return 0;

		float dmgTakenMul = g_mpPlrDmgTakenScale;

		bool selfDmg = false;
		if (dmg.Attacker is this)
		{
			@dmg.Attacker = null;
			selfDmg = true;
			dmgTakenMul *= Tweak::PlayerDmgTakenSelf;
		}
		else if (dmg.Attacker !is null && dmg.Attacker.Team != g_team_trap)
		{
			dmg = dmg.Attacker.DamageActor(this, dmg);
			dmgTakenMul *= Tweak::PlayerDmgTakenEnemy;
			SummonOwnerEvent(OwnerAggroEvent::Damage, dmg.Attacker);
		}
		else
		{
			dmgTakenMul *= Tweak::PlayerDmgTakenTrap;
			dmgTakenMul *= m_record.GetModifiers().TrapDamageMul(m_record);
			
			if (m_gentleTraps)
				dmgTakenMul *= 0.5f;
		}

		if (dmg.Miss)
		{
			AddFloatingMissed(dmg.Attacker);
			return 0;
		}

		Hooks::Call("PlayerDamage", @this, @dmg);

		auto modifiers = m_record.GetModifiers();
		if ((dmg.Melee || modifiers.RangedParry(this, dmg.Attacker, dmg)) && roll_chance(this, m_record.currStats.ParryChance))
		{
			float a = m_dirAngle - atan(dir.y, dir.x);
			a += (a > PI) ? -TwoPI : (a < -PI) ? TwoPI : 0;
			if ((abs(a) % TwoPI) < m_record.currStats.ParryArc)
			{
				%STAT Add parry-amount 1 m_record
				m_record.TriggerModifierEffects(Modifiers::EffectTrigger::Parry, dmg.Attacker);
				(Network::Message("PlayerParry")).SendToAll();
				NetParry();
				return 0;
			}
		}


		dmg.PhysicalDamage = int(dmg.PhysicalDamage * (1.0f + g_ngp * Tweak::EnemyNGPBaseDmgMul));
		dmg.FireDamage = int(dmg.FireDamage * (1.0f + g_ngp * Tweak::EnemyNGPBaseDmgMul));
		dmg.IceDamage = int(dmg.IceDamage * (1.0f + g_ngp * Tweak::EnemyNGPBaseDmgMul));
		dmg.LightningDamage = int(dmg.LightningDamage * (1.0f + g_ngp * Tweak::EnemyNGPBaseDmgMul));
		dmg.PoisonDamage = int(dmg.PoisonDamage * (1.0f + g_ngp * Tweak::EnemyNGPBaseDmgMul));
		dmg.PureDamage = int(dmg.PureDamage * (1.0f + g_ngp * Tweak::EnemyNGPBaseDmgMul));

		%STAT Add damage-incoming-phys dmg.PhysicalDamage m_record
		%STAT Add damage-incoming-fire dmg.FireDamage m_record
		%STAT Add damage-incoming-ice dmg.IceDamage m_record
		%STAT Add damage-incoming-light dmg.LightningDamage m_record
		%STAT Add damage-incoming-poison dmg.PoisonDamage m_record
		%STAT Add damage-incoming-pure dmg.PureDamage m_record


		dmgTakenMul *= modifiers.DamageTakenMul(this, dmg.Attacker, dmg) * m_buffs.DamageTakenMul();
		bool crit = dmg.Crit > 0;
		
		if (!crit && !dmg.DoT)
		{
			float receiveCritChance = m_buffs.ReceiveCritChance();
			if (receiveCritChance > 0.0f && randf() < receiveCritChance)
			{
				dmgTakenMul *= Tweak::EnemyCritDamage;
				crit = true;
			}
		}
		
		//if (g_diffLevel > m_record.level)
		//	dmgTakenMul *= 1.0f + min(3.0f, (g_diffLevel - m_record.level) * 0.04);
		
		if (modifiers.NonLethalDamage(this, dmg.Attacker, dmg))
			dmg.CanKill = false;
		
		if (!dmg.TrueStrike && !dmg.DoT)
		{
			vec2 d = dmg.Attacker !is null ? normalize(xy(m_unit.GetPosition() - dmg.Attacker.m_unit.GetPosition())) : dir;
		
			Modifiers::BlockSum block;
			modifiers.DamageBlock(this, dmg.Attacker, dmg, pos, d, block);
			modifiers.DamageBlock2(this, dmg.Attacker, dmg, pos, d, block); // Nice hack

			int sum = block.PhysicalDamage + block.FireDamage + block.IceDamage + block.LightningDamage + block.PoisonDamage + block.PureDamage + block.AnyDamage;
			if (sum > 0)
			{
				%STAT Add damage-blocked sum m_record
				
				if (block.PhysicalDamage > 0)
					PlayEffect(m_fxBlockPhysical, pos);
				else
					PlayEffect(m_fxBlockMagical, pos);
					
				m_record.TriggerModifierEffects(Modifiers::EffectTrigger::Blocked, dmg.Attacker);
				m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::DamageBlocked, sum);
				if (dmg.Melee)
					m_record.TriggerModifierEffects(Modifiers::EffectTrigger::BlockedMelee, dmg.Attacker);
			}
			
%defblock BlockDmg DmgType
			if (dmg.%%DmgType%% > 0)
				dmg.%%DmgType%% = max(0, dmg.%%DmgType%% - block.%%DmgType%%);
			if (dmg.%%DmgType%% > 0 && block.AnyDamage > 0)
			{
				int b = min(dmg.%%DmgType%%, block.AnyDamage);
				dmg.%%DmgType%% -= b;
				block.AnyDamage -= b;
			}
%endblock
			%block BlockDmg PhysicalDamage
			%block BlockDmg FireDamage
			%block BlockDmg IceDamage
			%block BlockDmg LightningDamage
			%block BlockDmg PoisonDamage
			
			//%block BlockAny PureDamage
			if (dmg.PureDamage > 0)
				dmg.PureDamage = max(0, dmg.PureDamage - block.PureDamage);
		}
		
		auto armorMul = m_buffs.ArmorMul();
		dmg.PhysicalDamage = damage_round(ApplyArmor(dmg.PhysicalDamage, float(armorMul.x * m_record.currStats.Armor), dmg.ArmorPenetration) * dmgTakenMul);
		dmg.FireDamage = damage_round(ApplyArmor(dmg.FireDamage, float(armorMul.y * m_record.currStats.ResistanceFire), dmg.ResistanceFirePenetration) * dmgTakenMul);
		dmg.IceDamage = damage_round(ApplyArmor(dmg.IceDamage, float(armorMul.y * m_record.currStats.ResistanceIce), dmg.ResistanceIcePenetration) * dmgTakenMul);
		dmg.LightningDamage = damage_round(ApplyArmor(dmg.LightningDamage, float(armorMul.y * m_record.currStats.ResistanceLightning), dmg.ResistanceLightningPenetration) * dmgTakenMul);
		dmg.PoisonDamage = damage_round(ApplyArmor(dmg.PoisonDamage, float(armorMul.y * m_record.currStats.ResistancePoison), dmg.ResistancePoisonPenetration) * dmgTakenMul);
		dmg.PureDamage = damage_round(dmg.PureDamage * dmgTakenMul);

		%STAT Add damage-taken-phys dmg.PhysicalDamage m_record
		%STAT Add damage-taken-fire dmg.FireDamage m_record
		%STAT Add damage-taken-ice dmg.IceDamage m_record
		%STAT Add damage-taken-light dmg.LightningDamage m_record
		%STAT Add damage-taken-poison dmg.PoisonDamage m_record
		%STAT Add damage-taken-pure dmg.PureDamage m_record

		int dmgAmnt = dmg.PhysicalDamage + damage_round(dmg.FireDamage * Tweak::FireImmediateDmgScale) + dmg.IceDamage + dmg.LightningDamage + dmg.PureDamage + damage_round(dmg.PoisonDamage * Tweak::PoisonImmmediateDmgScale);
		if (dmgAmnt <= 0 && dmg.PoisonDamage <= 0)
			return 0;

		if (!dmg.CanKill)
			dmgAmnt = min(m_record.CurrentHealth() - 1, dmgAmnt);
		
		m_returningDamage = true;
		
		if (!dmg.DoT)
		{
			if (selfDmg)
				m_record.TriggerModifierEffects(Modifiers::EffectTrigger::HurtSelf, this);
			else
				m_record.TriggerModifierEffects(Modifiers::EffectTrigger::HurtNonSelf, dmg.Attacker);
			
			m_record.TriggerModifierEffects(Modifiers::EffectTrigger::Hurt, dmg.Attacker);
			if (dmg.Melee)
				m_record.TriggerModifierEffects(Modifiers::EffectTrigger::HurtMelee, dmg.Attacker);
		}
		
		modifiers.DamageTaken(this, dmg.Attacker, dmgAmnt);
		m_returningDamage = false;
		
		
		if (m_record.trinketInventory.HasItem(g_hashed_phoenix_feather))
		{
			while (m_record.CurrentHealth() <= dmgAmnt)
			{
				if (m_record.potionChargesUsed >= m_record.currStats.PotionCharges)
					break;
				
				m_record.potionChargesUsed++;
				int healed = int(DrinkPotion().x + 0.5f);
				dmgAmnt = max(0, dmgAmnt - healed);
			}
		}
		
		float new = float(m_record.hp) - float(dmgAmnt) / float(GetMaxHp());
		m_record.hp = new;
		assert(m_record.hp, new);
		
		
		m_healthRegenC = int(Tweak::HealthRegenDelay * modifiers.HealthRegenDelayMul(this));
		
		if (!dmg.DoT)
		{
			if (selfDmg)
				m_buffs.AddAffliction(this, dmg.PhysicalDamage, dmg.FireDamage, dmg.IceDamage, dmg.LightningDamage, dmg.PoisonDamage);
			else
				m_buffs.AddAffliction(dmg.Attacker, dmg.PhysicalDamage, dmg.FireDamage, dmg.IceDamage, dmg.LightningDamage, dmg.PoisonDamage);
		}
		
		ivec2 ptsFromDmg = modifiers.PointsFromDamage(this, dmg.Attacker, dmgAmnt);
		if (ptsFromDmg.x > 0)
			this.Heal(ptsFromDmg.x);
		if (ptsFromDmg.y > 0)
			this.GiveMana(ptsFromDmg.y);

		%STAT Add damage-taken dmgAmnt m_record
		%STAT Max damage-taken-max dmgAmnt m_record

		m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::DamageTaken, dmgAmnt);
		m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::HealthLost, dmgAmnt);

		dmg.Damage = dmgAmnt;
		
		Hooks::Call("PlayerDamageTaken", @this, @dmg);
		
		DisplayDamaged(dmgAmnt, !selfDmg, crit, dmg.DoT);
		BroadcastNetDamage(dmg);
		
		if (new < 0)
			OnDeath(dmg, dir);
			
		return dmgAmnt;
	}
	
	void DisplayDamaged(int dmg, bool playSound, bool crit = false, bool dot = false)
	{
		AddFloatingHurt(dmg, crit ? 1 : 0, FloatingTextType::PlayerHurt);

		if (!dot)
			m_dmgColor = vec4(1, 0, 0, 1);
		
		if (m_record.CurrentHealth() >= 0)
		{
			if (m_gore !is null)
				m_gore.OnHit(dmg, xy(m_unit.GetPosition()), m_dirAngle);

			dictionary params = { { "damage", float(dmg) } };

			if (playSound && !dot)
				m_record.PlayVoice("hurt", params);

			if (playSound && dmg / float(m_record.MaxHealth()) >= 0.5f)
				m_record.PlayVoice("excessive_damage");
			else if (playSound && m_record.hp <= 0.1f)
				m_record.PlayVoice("close_to_death");
		}
	}

	void NetDamage(DamageInfo dmg, vec2 pos, vec2 dir) override
	{
		this.Damage(dmg, pos, dir);
	}

	void BroadcastNetDamage(DamageInfo di)
	{
		int damager = 0;
		if (di.Attacker !is null && !di.Attacker.m_unit.IsDestroyed())
			damager = di.Attacker.m_unit.GetId();

		m_lastSentStats.x = m_record.hp;
		(Network::Message("PlayerDamaged") << damager << di.Damage << m_record.hp << di.Weapon).SendToAll();
	}

	void OnDeath(DamageInfo di, vec2 dir) override
	{
		PlayerBase::OnDeath(di, dir);

		%STAT Add death-count 1 m_record

		int killerPeer = -1;

		auto plyKiller = cast<PlayerBase>(di.Attacker);
		if (plyKiller !is null)
			killerPeer = plyKiller.m_record.peer;

		(Network::Message("PlayerDied") << killerPeer << 0 << int(di.Damage) << di.Melee << di.Weapon).SendToAll();

		PlayerRecord@ killerRecord;
		if (plyKiller !is null)
			@killerRecord = plyKiller.m_record;

		auto hud = GetHUD();
		if (hud !is null)
			hud.OnDeath();

		m_record.KillSoulLinked();
	}

	bool IsDead() override { return !m_unit.IsValid() || m_record.IsDead(); }

	void OnLevelUp(int levels, int statPoints, int skillPoints)
	{
		(Network::Message("PlayerLevelUp")).SendToAll();
		
		PlaySound3D(Resources::GetSoundEvent("event:/sfx/ui/levelup_stereo"), m_unit);
		PlayEffect("effects/player/levelup.effect", m_unit);

		AddFloatingText(FloatingTextType::Pickup, Resources::GetString(".hud.levelup") + 
			"\n \\\"icn-skillpt\"" + skillPoints + "\\\"icn-attrpt\"" + statPoints, m_unit.GetPosition() + vec3(-8, 0, 0), Tweak::FloatingTextLevelUpTime);
	}

	void WarnCooldown(Skills::Skill@ skill, int ms) override
	{
		if (skill.GetTargetingMode() == Skills::TargetingMode::DirectionRepeating)
			return;
		//if (skill.m_type != PlayerSkillType::Spell)
		//	return;
	
		float skillSpeed = 1.0f;
		if (skill.m_type == PlayerSkillType::MainHand)
			skillSpeed = m_record.currStats.MainHand.AttackSpeed;
		else if (skill.m_type == PlayerSkillType::OffHand)
			skillSpeed = m_record.currStats.OffHand.AttackSpeed;
		else if (skill.m_type == PlayerSkillType::Spell)
			skillSpeed = m_record.currStats.CastSpeed;
		
		AddFloatingText(FloatingTextType::TimeCooldown, "[" + formatTime(ms / 1000.0f / skillSpeed, true, false, false, false, true) + "]", m_unit.GetPosition());
		PlaySound3D(m_sndCooldown, m_unit.GetPosition());
		m_record.PlayVoice("cooldown");
	}


	bool CanAfford(PointCost@ costA, PointCost@ costB)
	{
		vec2 mul = m_record.GetModifiers().SkillCostMul(this);
		if (GetVarBool("cht_plr_free_health_cost"))
			mul.x = 0;
		if (GetVarBool("cht_plr_free_mana_cost") || m_buffs.FreeMana())
			mul.y = 0;
		
		vec2 maxPts(float(m_record.MaxHealth()), float(m_record.MaxMana()));
		vec2 currPts = vec2(m_record.hp, m_record.mana) * maxPts;
		
		auto fCost = costA.percentageMaxCost * maxPts + costA.percentageCurrCost * currPts;
		fCost += vec2(costA.flatCost.x, costA.flatCost.y);
		fCost *= mul * costA.multiplier;
		auto useCost = m_record.GetModifiers().UsePoints(this, fCost);
		fCost += vec2(useCost.x, useCost.y) * mul;
		
		auto fCost2 = costB.percentageMaxCost * maxPts + costB.percentageCurrCost * currPts;
		fCost2 += vec2(costB.flatCost.x, costB.flatCost.y);
		fCost2 *= mul * costB.multiplier;
		useCost = m_record.GetModifiers().UsePoints(this, fCost2);
		fCost2 += vec2(useCost.x, useCost.y) * mul;
		
		auto fCostP = (fCost + fCost2) / maxPts;
		int dashCost = costA.dashCost + costB.dashCost;
		
		if (fCostP.x > 0 && m_record.hp < fCostP.x)
			return false;
		if (fCostP.y > 0 && m_record.mana < fCostP.y)
			return false;
		if (dashCost > 0 && m_record.dashCharges < dashCost)
			return false;
		
		return true; 
	}

	bool UsePoints(bool spend, bool warn, PointCost@ cost) override
	{
		vec2 mul = m_record.GetModifiers().SkillCostMul(this);
		if (GetVarBool("cht_plr_free_health_cost"))
			mul.x = 0;
		if (GetVarBool("cht_plr_free_mana_cost") || m_buffs.FreeMana())
			mul.y = 0;
		
		vec2 maxPts(float(m_record.MaxHealth()), float(m_record.MaxMana()));
		vec2 currPts = vec2(m_record.hp, m_record.mana) * maxPts;
		
		auto fCost = cost.percentageMaxCost * maxPts + cost.percentageCurrCost * currPts;
		fCost += vec2(cost.flatCost.x, cost.flatCost.y);
		fCost *= mul * cost.multiplier;
		auto useCost = m_record.GetModifiers().UsePoints(this, fCost);
		fCost += vec2(useCost.x, useCost.y) * mul;
		auto fCostP = fCost / maxPts;

		if (fCostP.x > 0 && m_record.hp < fCostP.x)
		{
			if (warn)
			{
				int diff = int(ceil((fCostP.x - m_record.hp) * maxPts.x));
				AddFloatingText(FloatingTextType::NoHealth, "(-" + diff + ")", m_unit.GetPosition());
				PlaySound3D(m_sndNoMana, m_unit.GetPosition());
			}
			return false;
		}
		
		if (fCostP.y > 0 && m_record.mana < fCostP.y)
		{
			if (warn)
			{
				int diff = int(ceil((fCostP.y - m_record.mana) * maxPts.y));
				AddFloatingText(FloatingTextType::NoMana, "(-" + diff + ")", m_unit.GetPosition());
				PlaySound3D(m_sndNoMana, m_unit.GetPosition());
				m_record.PlayVoice("no_mana");
			}
			return false;
		}
		
		if (cost.dashCost > 0 && m_record.dashCharges < cost.dashCost)
		{
			if (warn)
			{
				//int diff = int(ceil((fCostP.y - m_record.mana) * maxPts.y));
				//AddFloatingText(FloatingTextType::NoCharges, "(-" + diff + ")", m_unit.GetPosition());
				//PlaySound3D(m_sndNoMana, m_unit.GetPosition());
				//m_record.PlayVoice("no_mana");
				AddFloatingText(FloatingTextType::NoCharges, "!", m_unit.GetPosition());
			}
			return false;
		}
		
		if (spend)
		{
			if (fCostP.x > 0)
			{
				m_record.hp -= fCostP.x;
				int healthSpent = int(fCost.x);
				//Stats::Add("spent-health", healthSpent, m_record);
				m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::HealthSpent, healthSpent);
				m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::HealthLost, healthSpent);
				m_healthRegenC = int(Tweak::HealthRegenDelay * m_record.GetModifiers().HealthRegenDelayMul(this));
			}
			
			if (fCostP.y > 0)
			{
				m_record.mana -= fCostP.y;
				int manaSpent = int(fCost.y);
				if (!g_inTown)
					%STAT Add spent-mana manaSpent m_record
				m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::ManaSpent, manaSpent);
				m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::ManaLost, manaSpent);
			}
			
			if (cost.dashCost > 0)
			{
				if (m_record.dashCharges == m_record.currStats.MaxDashes)
					m_dashRechargeC = 0;
				m_record.dashCharges -= cost.dashCost;
				
				if (cost.dashCost < 0)
					m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::DashChargeGained, cost.dashCost);
				else
					m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::DashChargeSpent, cost.dashCost);
				
				(Network::Message("PlayerSyncDashes") << m_record.dashCharges).SendToAll();
			}
		}
		
		return true; 
	}
	
	
	
	uint m_lastCollideTime;
	UnitPtr m_lastCollideUnit;
	
	void Collide(UnitPtr unit, vec2 pos, vec2 normal, Fixture@ fxSelf, Fixture@ fxOther)
	{
		for (uint i = 0; i < m_skills.length(); i++)
			m_skills[i].OnCollide(unit, pos, normal, fxOther);

		
		if (fxOther.IsSensor())
			return;
			
		auto nowT = g_scene.GetTime();
		if (m_lastCollideUnit == unit)
		{
			if ((m_lastCollideTime + 100) > nowT)
				return;
		}
			
		m_lastCollideUnit = unit;
		
		auto actor = cast<Actor>(unit.GetScriptBehavior());
		if (actor is null)
			return;

		auto player = cast<PlayerBase>(actor);
		if (player !is null)
			return;

		m_record.TriggerModifierEffects(Modifiers::EffectTrigger::Collide, actor);
		m_lastCollideTime = nowT;
	}

	void OnPotionCharged() override
	{
		(Network::Message("PlayerPotionCharged")).SendToAll();
		PlayerBase::OnPotionCharged();
	}

	vec2 DrinkPotion()
	{
		PlayerStats@ currStats = m_record.currStats;

		float healAmnt = currStats.PotionHeal;
		float manaAmnt = currStats.PotionMana;

		GiveMana(int(manaAmnt + 0.5f));
		Heal(int(healAmnt + 0.5f));
		
		//if (m_record.currStats.MaxDashes > m_record.dashCharges)
		//	GiveDashCharges(m_record.currStats.MaxDashes - m_record.dashCharges);

		PlaySound3D(Resources::GetSoundEvent("event:/sfx/player/potion_use"), m_unit.GetPosition());
		(Network::Message("PlayerSyncPotion") << m_record.potionChargesUsed).SendToAll();

		m_shadeSpawnC = 10000;

		if (!g_inTown)
			%STAT Add potion-charges-used 1 m_record
		m_record.TriggerModifierEffects(Modifiers::EffectTrigger::DrinkPotion, this);
	
		return vec2(healAmnt, manaAmnt);
	}


	bool BlockProjectile(IProjectile@ proj) override
	{
		auto block = m_record.GetModifiers().ProjectileBlock(this, proj);
		if (block)
		{
			auto pb = cast<ProjectileBase>(proj);
			vec3 pos;
			
			if (pb !is null)
				pos = pb.m_unit.GetPosition();
			else
				pos = m_unit.GetPosition();
			
			PlayEffect(m_fxBlockProjectile, xy(pos));
			PlaySound3D(m_sndBlockProjectile, pos);
			return true;
		}
	
		return false;
	}

	void QueuedPathfind(array<vec2>@ path)
	{
		m_cinemaPathFollower.QueuedPathfind(path);
	}

	int m_comboCount;
	int m_comboC;
	void GiveComboCount(int count, bool onlyTriggerNoSustain)
	{
		if (m_record.currStats.ComboCountMax <= 0)
			return;
		
		if (onlyTriggerNoSustain && m_comboActive)
			return;
		
		m_comboCount += count;
		m_comboC = 0;
		
		if (m_comboCount >= m_record.currStats.ComboCountMax && !m_comboActive)
		{
			(Network::Message("PlayerSyncCombo") << true).SendToAll();
			NetSyncCombo(true);
			m_record.TriggerModifierEffects(Modifiers::EffectTrigger::Combo, this);
		}
		
		if (m_comboActive)
		{
			%STAT Max combo-max m_comboCount m_record
		}
	}

	void GiveCombo()
	{
		if (m_record.currStats.ComboCountMax <= 0 || m_comboActive)
			return;
		
		m_comboCount += 1;
		m_comboC = 0;
		
		(Network::Message("PlayerSyncCombo") << true).SendToAll();
		NetSyncCombo(true);
		m_record.TriggerModifierEffects(Modifiers::EffectTrigger::Combo, this);
	}

	int m_usableSentinelC;
	int m_kbmMoveDirDelay;
	void Update(int dt) override
	{
		if (m_record.playerClass is null)
			return;
		
		if (m_summonOwnerEventC > 0)
			m_summonOwnerEventC -= dt;
		
		m_usableSentinelC -= dt;
		if (m_usableSentinelC < 0)
		{
			m_usableSentinelC = 250;
			for (uint i = 0; i < m_usables.length(); i++)
			{
				if (m_usables[i].m_usable.IsInside(m_unit))
					continue;
				m_usables.removeAt(i);
				break;
			}
		}
		
		m_record.modifiers.Update(this, dt);
		m_record.RefreshStats();
		m_record.modifiers.ModifySkills(this, m_skills);
		auto modifiers = m_record.GetModifiers();
		
		{
			uint summNum = m_record.summons.length();
			for (uint i = 0; i < summNum; i++)
			{
				auto@ summ = m_record.summons[i];
				summ.m_maxSummons = 1;
				
				for (uint j = 0; j < summ.m_units.length(); j++)
				{
					if (summ.m_units[j] is null || summ.m_units[j].GetUnit().IsDestroyed())
					{
						summ.m_units.removeAt(j);
						summ.m_weaponInfo.removeAt(j);
						j--;
					}
				}
				
			}
			
			for (uint i = 0; i < summNum; i++)
			{
				auto@ summ = m_record.summons[i];
				for (uint j = 0; j < infiniteSummons.length(); j++)
				{
					if (summ.m_prod is infiniteSummons[j])
					{
						summ.m_maxSummons = 1000;
						break;
					}
				}
			}
			
			modifiers.ModifyPlayerSummons(this);
			
			for (uint i = 0; i < summNum; i++)
			{
				auto@ summ = m_record.summons[i];
				int numKill = summ.m_units.length() - max(0, summ.m_maxSummons);
				for (int n = 0; n < numKill; n++)
				{
					if (Network::IsServer())
						summ.m_units[0].Destroy();
					else
						(Network::Message("UnitDestroyed") << summ.m_units[0].GetUnit()).SendToHost();
					
					summ.m_units.removeAt(0);
					summ.m_weaponInfo.removeAt(0);
				}
			}
		}
		
	
%PROFILE_START BaseUpdate
		PlayerBase::Update(dt);
%PROFILE_STOP

%PROFILE_START Buffs
		auto buffDmg = m_buffs.Update(dt);
		if (buffDmg !is null)
		{
			int dmgAmnt = buffDmg.Damage;
			if (!buffDmg.CanKill)
				dmgAmnt = min(m_record.CurrentHealth() - 1, dmgAmnt);
			else
			{
				if (m_record.trinketInventory.HasItem(g_hashed_phoenix_feather))
				{
					while (m_record.CurrentHealth() <= dmgAmnt)
					{
						if (m_record.potionChargesUsed >= m_record.currStats.PotionCharges)
							break;
						
						m_record.potionChargesUsed++;
						int healed = int(DrinkPotion().x + 0.5f);
						dmgAmnt = max(0, dmgAmnt - healed);
					}
				}
			}
			
			m_record.hp = float(m_record.hp) - float(dmgAmnt) / float(GetMaxHp());
			
			DisplayDamaged(dmgAmnt, false, false, buffDmg.DoT);
			BroadcastNetDamage(buffDmg);
			
			%STAT Add damage-taken dmgAmnt m_record
			%STAT Max damage-taken-max dmgAmnt m_record
			
			// m_dmgColor = vec4(1, 0, 0, 1);
			
			if (m_record.hp <= 0)
				OnDeath(buffDmg, vec2(cos(m_dirAngle), sin(m_dirAngle)));
		}
%PROFILE_STOP
		
		/*
		auto sCurse = m_record.shadowCurses / 100.0f;
		m_shadeSpawnC -= int(dt * pow(sCurse, 0.5f));
		if (m_shadeSpawnC <= 0)
		{
			if (randf() < 0.5f)
			{
				if (Network::IsServer())
					PlayerHandler::PlayerSpawnShade(0);
				else
					Network::Message("PlayerSpawnShade").SendToHost();
			}
			
			m_shadeSpawnC = 2500;
		}
		*/
		
		
		auto input = GetInput();
		
		auto aimDir = Focus::Obtain(Focus::GAMEPLAY) ? input.AimDir : vec2(0,1);
		auto moveDir = input.MoveDir;

		int controllerMoveDir = GetVarInt("g_controller_move_dir");
		if (input.UsingGamepad && controllerMoveDir >= 0)
		{
			if (!m_usingController)
			{
				input.AimDir = vec2(0,1);
				m_usingController = true;
			}

			if (aimDir.x == 0.0f && aimDir.y == 0.0f)
			{
				if (moveDir.x != 0.0f || moveDir.y != 0.0f)
				{
					aimDir = moveDir;
					m_dirAngle = atan(aimDir.y, aimDir.x);
				}
				else
					aimDir = m_prevDir;
			}

			m_prevDir = aimDir;
		}
		else if (controllerMoveDir >= 1)
		{
			m_usingController = false;

			bool activeSkill = false;
			for (uint i = 0; i < m_skills.length(); i++)
			{
				if (m_skills[i].IsActive())
				{
					activeSkill = true;
					m_prevDir = aimDir;
					m_kbmMoveDirDelay = 60;
					break;
				}
			}

			if (!activeSkill && m_kbmMoveDirDelay <= 0 && Focus::Obtain(Focus::GAMEPLAY))
			{
				aimDir = moveDir;

				if (moveDir.x == 0.0f && moveDir.y == 0.0f)
					aimDir = m_prevDir;

				m_dirAngle = atan(aimDir.y, aimDir.x);
				m_prevDir = aimDir;
			}

			if (m_kbmMoveDirDelay > 0)
				m_kbmMoveDirDelay -= dt;
		}
		else if (input.UsingGamepad && controllerMoveDir < 0)
		{
			if (aimDir.x == 0.0f && aimDir.y == 0.0f)
				aimDir = m_prevDir;

			m_prevDir = aimDir;
		}

		if (m_buffs.Confuse())
		{
			aimDir *= -1;
			moveDir *= -1;
		}

		if (m_buffs.LockMovement() || CVars::ChtFreecamSpeed > 0.0f)
			moveDir = vec2();

		if (m_buffs.LockRotation())
			aimDir = vec2(cos(m_dirAngle), sin(m_dirAngle));


		PlayerStats@ currStats = m_record.currStats;

		if (m_record.currStats.ComboCountMax > 0)
		{
			int resetTime = m_comboActive ? currStats.ComboSustainResetTime : currStats.ComboObtainResetTime;
			if (m_comboC < resetTime)
			{
				m_comboC += dt;
				if (m_comboC >= resetTime)
				{
					m_comboCount = 0;
					m_comboC = 0;
					if (m_comboActive)
					{
						(Network::Message("PlayerSyncCombo") << false).SendToAll();
						NetSyncCombo(false);
					}
				}
			}
		}


		float regenMul = 1.0f;
		
%PROFILE_START Regen
		m_record.mana = clamp(m_record.mana + dt / 1000.0f * currStats.ManaRegen * regenMul * currStats.ManaGain / currStats.Mana, 0.0f, 1.0f);
		
		auto hpRegenGain = currStats.HealthRegen * regenMul * currStats.HealthGain;
		if ((hpRegenGain > 0) && (m_healthRegenC > 0))
			m_healthRegenC -= dt;
		else
			m_record.hp = clamp(m_record.hp + dt / 1000.0f * hpRegenGain / currStats.Health, 0.0f, 1.0f);
		
		
		if (m_record.hp <= 0)
			OnDeath(DamageInfo(), m_lastDirection);
		
		if (m_record.dashCharges < currStats.MaxDashes)
		{
			m_dashRechargeC += dt;
			if (m_dashRechargeC >= (currStats.DashRechargeMul * Tweak::BaseDashRechargeTime))
			{
				m_record.dashCharges++;
				m_dashRechargeC = 0;

				m_record.TriggerModifierQuantityEffects(Modifiers::QuantityTrigger::DashChargeGained, 1);

				(Network::Message("PlayerSyncDashes") << m_record.dashCharges).SendToAll();
			}
		}
		else
			m_dashRechargeC = 0;
		
%PROFILE_STOP
		
		if (abs(m_lastSentStats.x - m_record.hp) > 0.001f || abs(m_lastSentStats.y - m_record.mana) > 0.001f)
		{
			m_lastSentStats.x = m_record.hp;
			m_lastSentStats.y = m_record.mana;

			(Network::Message("PlayerSyncStats") << m_lastSentStats.x << m_lastSentStats.y).SendToAll();
		}

		auto baseGameMode = cast<BaseGameMode>(g_gameMode);

		bool freezeMovement = !Focus::Obtain(Focus::GAMEPLAY) || IsDead() || baseGameMode.ShouldFreezeControls() || (CinemaManager::g_cinematicC > 0 && CinemaManager::g_frozenControls);
		bool freezeControls = !Focus::Obtain(Focus::GAMEPLAY) || freezeMovement;
		
		int snapAngleCount = GetVarInt("g_movedir_snap");
		if (snapAngleCount > 0 && lengthsq(moveDir) > 0)
		{
			float snapAngle = TwoPI / float(snapAngleCount);
			float curAngle = atan(moveDir.y, moveDir.x);
			float snappedAngle = round(curAngle / snapAngle) * snapAngle;
			moveDir.x = cos(snappedAngle);
			moveDir.y = sin(snappedAngle);
		}

		snapAngleCount = GetVarInt("g_aimdir_snap");
		if (snapAngleCount > 0)
		{
			float snapAngle = TwoPI / float(snapAngleCount);
			float curAngle = atan(aimDir.y, aimDir.x);
			float snappedAngle = round(curAngle / snapAngle) * snapAngle;
			aimDir.x = cos(snappedAngle);
			aimDir.y = sin(snappedAngle);
		}

		if (m_potionDelay > 0)
			m_potionDelay -= dt;

		if (!freezeControls)
		{
		
%PROFILE_START SkillInput
			
			auto chargeDir = moveDir;
			if (lengthsq(chargeDir) <= 0 || !GetVarBool("g_charge_movedir"))
				chargeDir = aimDir;
				
			bool canUseSkill = true;
			for (uint i = 0; i < m_uncancellableSkills.length(); i++)
			{
				if (m_uncancellableSkills[i].IsUncancellableActive())
				{
					canUseSkill = false;
					break;
				}
			}
			
			if (!m_targetHelper.Update(dt, aimDir) && canUseSkill)
			{
				uint chargeIdx = 0;
				
				if (m_skills.length() > chargeIdx)
					m_targetHelper.CheckUseSkill(m_skills[chargeIdx], chargeDir);
				
				for (uint i = 0; i < m_skills.length(); i++)
				{
					if (i != chargeIdx)
						m_targetHelper.CheckUseSkill(m_skills[i], aimDir);
				}
			}
			
			if (input.Use.Pressed)
			{
				auto usable = GetTopUsable();
				if (usable !is null && usable.CanUse(this))
				{
					UnitPtr unit = usable.GetUseUnit();
					UnitProducer@ prod = unit.GetUnitProducer();
					if (prod !is null && prod.GetNetSyncMode() == NetSyncMode::None)
						usable.Use(this);
					else if (Network::IsServer())
					{
						(Network::Message("UseUnit") << unit << m_unit).SendToAll();
						usable.Use(this);
					}
					else
						(Network::Message("UseUnitSecure") << unit).SendToHost();
				}
			}

			if (input.Potion.Pressed && currStats.PotionCharges > 0 && m_potionDelay <= 0)
			{
				if (m_record.potionChargesUsed >= currStats.PotionCharges)
				{
					m_record.PlayVoice("potion_empty");
					AddFloatingText(FloatingTextType::NoCharges, "!", m_unit.GetPosition());
				}
				else
				{
					m_record.potionChargesUsed++;
					m_potionDelay = GetVarInt("g_potion_delay");
					DrinkPotion();
				}
			}
%PROFILE_STOP
		}


		PhysicsBody@ bdy = m_unit.GetPhysicsBody();
		// If we have no physics body, we can't do much (player died)
		if (bdy is null)
			return;

%PROFILE_START Moving
		float moveSpeed = 1.0f;
		if (CinemaManager::g_cinematicC > 0 && CinemaManager::g_frozenControls)
		{
			if (CinemaManager::g_forceMoveTarget.IsValid())
			{
				moveSpeed *= CinemaManager::g_forceMoveSpeed;
				moveDir = m_cinemaPathFollower.FollowPath(xy(m_unit.GetPosition()), xy(CinemaManager::g_forceMoveTarget.GetPosition())) * moveSpeed;
				m_dirAngle = m_cinemaPathFollower.m_visualDir;
				aimDir = vec2(cos(m_dirAngle), sin(m_dirAngle));
			}
		}
		else
		{
			moveSpeed *= currStats.MoveSpeed;
			
			//if (m_poisonDmgPool > 0)
			//	moveSpeed *= 0.8;
			
			float comboSlowScale = m_comboActive ? 0.5f : 1.0f;
			float slowScale = modifiers.SlowScale(this);
			moveSpeed *= m_buffs.MoveSpeedMul(slowScale * comboSlowScale);
			
			
			for (uint i = 0; i < m_skills.length(); i++)
			{
				float speedMod = m_skills[i].GetMoveSpeedMul();
				if (speedMod >= 1.0f)
					moveSpeed *= speedMod;
				else
					moveSpeed *= lerp(1.0f, speedMod, m_skills[i].m_modSlowScale * comboSlowScale);
			}
			
			array<Tileset@>@ tilesets = g_scene.FetchTilesets(xy(m_unit.GetPosition()));
			for (int i = tilesets.length() - 1; i >= 0; i--)
			{
				auto tsd = tilesets[i].GetData();
				if (tsd is null)
					continue;
				
				SValue@ tilesetSpeed = tsd.GetDictionaryEntry("walk-speed");
				if (tilesetSpeed !is null && tilesetSpeed.GetType() == SValueType::Float)
				{
					moveSpeed *= tilesetSpeed.GetFloat();
					break;
				}
			}
			
			if (moveSpeed > 0)
				moveSpeed = max(min(moveSpeed * Tweak::PlayerSpeedBase, Tweak::PlayerSpeedMax), Tweak::PlayerSpeedMin);
			else if (moveSpeed < 0)
				moveSpeed = -max(min(-moveSpeed * Tweak::PlayerSpeedBase, Tweak::PlayerSpeedMax), Tweak::PlayerSpeedMin);
			else
				moveSpeed = 0;
			
			if (g_inTown && moveSpeed < 8.0f) {
        moveSpeed = 8.0f;
      }
      
      if (m_comboActive)
        moveSpeed *= 1.2f;
			
			float minSpeed = m_buffs.MinSpeed();
			
			auto moveDirLen = length(moveDir);
			if (moveDirLen < minSpeed)
				moveDir = normalize((moveDirLen > 0) ? moveDir : aimDir) * minSpeed;
			
			moveDir = freezeMovement ? vec2(0) : (moveDir * moveSpeed);
			
			for (uint i = 0; i < m_skills.length(); i++)
			{
				vec2 skillMoveDir = m_skills[i].GetMoveDir(moveDir);
				if (skillMoveDir.x != 0 || skillMoveDir.y != 0)
				{
					moveDir = skillMoveDir;
					break;
				}
			}

			float slippery = m_buffs.MoveSlipperyMul();
			if (slippery < 1.0f)
			{
				vec2 currentVelocity = bdy.GetLinearVelocity();
				moveDir = lerp(currentVelocity, moveDir, slippery * (dt / 1000.0f));
			}
		}

		vec2 dir = vec2(cos(m_dirAngle), sin(m_dirAngle));

		float distance = length(moveDir);
		if (distance >= 0.25f)
		{
			int dist = int(distance * 10.0f);
			%STAT Add units-traveled dist m_record
		}

		if (distance > 0)
			GameEvents::PlayerMoved(this, moveDir);
		
		bdy.SetLinearVelocity(moveDir);
		
		float facing = atan(aimDir.y, aimDir.x);
		SetAngle(facing);
		
		bool walking = (distance > 0.1);
		
		if (m_footsteps !is null)
			m_footsteps.Update(dt);
		
%PROFILE_STOP
		
		
%PROFILE_START SkillUpdate
/*
		if (walking)
			m_unit.SetUnitTimeScale(moveSpeed/Tweak::PlayerSpeedBase);
		else
			m_unit.SetUnitTimeScale(1.0f);
*/
		vec2 ssMul = m_buffs.SkillSpeed();
		for (uint i = 0; i < m_skills.length(); i++)
		{
			if (m_skills[i].m_type == PlayerSkillType::MainHand)
			{
				m_skills[i].SetSkillSpeed(currStats.MainHand.AttackSpeed * ssMul.x);
				m_skills[i].Update(int(currStats.MainHand.AttackSpeed * ssMul.x * dt), walking, aimDir);
			}
			else if (m_skills[i].m_type == PlayerSkillType::OffHand)
			{
				m_skills[i].SetSkillSpeed(currStats.OffHand.AttackSpeed * ssMul.x);
				m_skills[i].Update(int(currStats.OffHand.AttackSpeed * ssMul.x * dt), walking, aimDir);
			}
			else if (m_skills[i].m_type == PlayerSkillType::Spell)
			{
				m_skills[i].SetSkillSpeed(currStats.CastSpeed * ssMul.y);
				m_skills[i].Update(int(currStats.CastSpeed * ssMul.y * dt), walking, aimDir);
			}
			else
			{
				m_skills[i].SetSkillSpeed(1.0f);
				m_skills[i].Update(dt, walking, aimDir);
			}
		}
%PROFILE_STOP

		if (walking)
			SetBodyAnim(g_walkAnim, moveSpeed / Tweak::PlayerSpeedBase, false);
		else
			SetBodyAnim(g_idleAnim, 1.0f, false);


		vec2 currDir = bdy.GetLinearVelocity();
		if (length(currDir) > 0.2)
			m_lastDirection = currDir;
		
		m_forceSendMoveC -= dt;
		if (m_forceSendMoveC <= 0)
		{
			SendPlayerMove(dir, true);
			m_forceSendMoveC = 1000;
		}
		else
			SendPlayerMove(dir);
	}
	
	void SendPlayerMove(vec2 dir, bool force = false)
	{
		auto pos = xy(m_unit.GetPosition());

		if (!force)
		{
			if (distsq(m_lastSentPos, pos) > 1 || distsq(m_lastSentDir, dir) > 0.01)
			{
				m_lastSentPos = pos;
				m_lastSentDir = dir;
				(Network::Message("PlayerMove") << pos << dir).SendToAll();
			}
		}
		else
		{
			m_lastSentPos = pos;
			m_lastSentDir = dir;
			(Network::Message("PlayerMoveForce") << pos << dir).SendToAll();
		}
	}

	bool PreRender(int idt)
	{
		if (m_unit.IsDestroyed())
			return true;

		return false;
	}

	void Destroyed() override
	{
		PlayerBase::Destroyed();
		m_targetHelper.OnDestroyed();
	}

	bool ShootThrough(Actor@ attacker, vec2 pos, vec2 dir) override 
	{ 
		return m_buffs.ShootThrough(); 
	}

	void RefreshMarkerScene() override
	{
		/*
			g_laser_sight

			0 = none
			1 = marker
			2 = laser
			4 = auto

			none = 0
			marker = 1
			laser = 2
			both = 3
			auto marker = 5
			auto laser = 6
			auto both = 7
		*/

		auto input = GetInput();
		if (input is null)
			return;

		int laserSight = GetVarInt("g_laser_sight");
		bool usingAuto = (laserSight & 4 != 0);

		if (laserSight & 1 != 0)
		{
			if (usingAuto)
			{
				if (input.UsingGamepad)
					m_unitScene.AddScene(m_markerFx, 0, vec2(), 0, 0);
			}
			else
				m_unitScene.AddScene(m_markerFx, 0, vec2(), 0, 0);

		}

		if (m_targetHelper.m_targetingSkill is null)
		{
			if (laserSight & 2 != 0)
			{
				if (usingAuto)
				{
					if (input.UsingGamepad)
						m_unitScene.AddScene(m_aimLaserFx, 0, vec2(), 0, 0);
				}
				else
					m_unitScene.AddScene(m_aimLaserFx, 0, vec2(), 0, 0);
			}
		}
	}
}

