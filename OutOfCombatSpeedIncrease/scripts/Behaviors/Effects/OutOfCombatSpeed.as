const int CHECK_INTERVAL_MS = 250;
const int ENEMY_SCAN_RADIUS = 600;
const int DISTANCE_THRESHOLD_ENEMY = 280;
const int DISTANCE_THRESHOLD_TRAP = 150;
const int BUFF_DURATION_MS = 999999;
const int BUFF_REAPPLY_DELAY_MS = 3000;
const float BUFF_MULTIPLIER_DEFAULT = 1.0f;
const float BUFF_MULTIPLIER_TOWN = 1.2f;
const int TOGGLE_HOLD_THRESHOLD = 1500;

class OutOfCombatSpeedManager
{
  Player@ m_player;
  ActorBuffDef@ m_buff;
  ActorBuff@ m_activeBuff;
  int m_checkTimer;
  int m_outOfCombatTimer = 0;
  bool m_inBossFight;
  bool m_wasRecentlyInCombat = false;

  bool m_isEnabled = true;
  bool m_wasHoldingToggleKey = false;
  int m_toggleKeyHoldTime = 0;

  OutOfCombatSpeedManager(Player@ player)
  {
    @m_player = player;
    @m_buff = LoadActorBuff("players/shared/buffs/out_of_combat_speed.sval");
    m_checkTimer = CHECK_INTERVAL_MS;
    m_inBossFight = cast<BossLevel>(g_gameMode) !is null;

    @m_activeBuff = null;
    auto buffs = player.GetBuffList().m_buffs;
    for (uint i = 0; i < buffs.length(); i++)
    {
      if (buffs[i].m_def is m_buff)
      {
        @m_activeBuff = buffs[i];
        break;
      }
    }
  }

  void Update(int dt)
  {
    if (m_player is null || m_buff is null || !m_isEnabled)
      return;

    m_checkTimer -= dt;

    if (m_checkTimer > 0)
      return;

    m_checkTimer = CHECK_INTERVAL_MS;
    
    if (g_inTown) {
      ApplyBuff(BUFF_MULTIPLIER_TOWN);
      return;
    }

    if (m_inBossFight) {
      RemoveBuff();
      return;
    }
    
    auto nearbyActors = g_scene.FetchActorsWithOtherTeam(m_player.Team, xy(m_player.m_unit.GetPosition()), ENEMY_SCAN_RADIUS);
    vec2 playerPos = xy(m_player.m_unit.GetPosition());

    for (uint i = 0; i < nearbyActors.length(); i++)
    {
      auto npc = cast<CompositeActorBehaviorNPC>(nearbyActors[i].GetScriptBehavior());
      if (npc !is null)
        continue; // Friendly NPCs outside town, skip

      if (nearbyActors[i].GetDebugName() == "actors/misc/treeline_spawner.unit")
        continue; // These invisible spawners are everywhere in forest maps, preventing the buff from ever applying, skip

      auto enemy = cast<CompositeActorBehavior>(nearbyActors[i].GetScriptBehavior());
      if (enemy is null || enemy.m_dead)
        continue;

      bool isTrap = enemy.m_props.m_team == g_team_trap;

      // Traps like gargoyles keep aggro forever, need to ignore them here
      if (enemy.m_target is m_player && !isTrap) {
        RemoveBuff();
        return;
      }
      
      vec2 enemyPos = xy(nearbyActors[i].GetPosition());
      float distance = length(playerPos - enemyPos);
      int threshold = isTrap ? DISTANCE_THRESHOLD_TRAP : DISTANCE_THRESHOLD_ENEMY;
      
      if (distance <= threshold) {
        RemoveBuff();
        return;
      }
    }

    ApplyBuff();
  }

  void OnPlayerDamaged()
  {
    RemoveBuff();
  }

  void RemoveBuff()
  {
    m_wasRecentlyInCombat = true;
    m_outOfCombatTimer = 0;
    
    if (m_activeBuff !is null && m_activeBuff.m_duration > 0)
      m_activeBuff.Clear();
  }

  void ApplyBuff(float buffMultiplier = BUFF_MULTIPLIER_DEFAULT)
  {
    if (m_wasRecentlyInCombat)
    {
      m_outOfCombatTimer += CHECK_INTERVAL_MS;
      
      if (m_outOfCombatTimer >= BUFF_REAPPLY_DELAY_MS)
      {
        m_wasRecentlyInCombat = false;
        m_outOfCombatTimer = 0;
      }
    }
    
    if (!m_wasRecentlyInCombat && (m_activeBuff is null || m_activeBuff.m_duration <= 0))
    {
      @m_activeBuff = ActorBuff(m_player, m_buff, 1.0f, false);
      m_activeBuff.m_duration = BUFF_DURATION_MS;
      m_activeBuff.m_def.m_mulSpeed = vec2(buffMultiplier, buffMultiplier);
      m_player.ApplyBuff(m_activeBuff);
    }
    else if (!m_wasRecentlyInCombat && m_activeBuff !is null)
      m_activeBuff.m_duration = BUFF_DURATION_MS;
  }
  
  void HandleManualToggle(int dt)
  {
    auto input = GetInput();

    if (!input.Use.Down)
    {
      m_wasHoldingToggleKey = false;
      m_toggleKeyHoldTime = 0;
      return;
    }

    if (!m_wasHoldingToggleKey)
    {
      m_wasHoldingToggleKey = true;
      m_toggleKeyHoldTime = 0;
      return;
    }

    m_toggleKeyHoldTime += dt;
    
    if (m_toggleKeyHoldTime >= TOGGLE_HOLD_THRESHOLD)
    {
      m_isEnabled = !m_isEnabled;

      if (m_isEnabled)
      {
        AddFloatingText(FloatingTextType::Pickup, "Enabled speed boost", m_player.m_unit.GetPosition(), 1500);
        RemoveBuff();
      }
      else
      {
        AddFloatingText(FloatingTextType::Pickup, "Disabled speed boost", m_player.m_unit.GetPosition(), 1500);
      }

      m_toggleKeyHoldTime = 0;
      m_wasHoldingToggleKey = false;
    }
  }
}