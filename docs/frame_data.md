# Frame data (generated)

Written by `tools/frame_data_sheet.tscn` on 2026-11-25 from `data/moves`
and each character's tuning. Rerun it after changing moves or tuning, then
put this header back:

    godot --headless res://tools/frame_data_sheet.tscn -- out=docs/frame_data.md

Conventions are in `tools/frame_data.gd`: "hit on" is the first active
frame (60 Hz, counted from 1); advantage = stun - (active + recovery), with
contact on the first active frame, no mashing and no cancels;
`tests/frame_data_test` holds that formula to the sim. BT3 numbers to
compare with: [bt3_sauce.md](bt3_sauce.md) §3 and "Measured in the port".

Guard m/h/l: P plain, K ki guard, O push-off, S push-stop, U unblockable.

### Brawler

| move | role | height | hit on | active | recovery | total | damage | dmg % | on hit | adv hit | guard stun | adv guard | adv push-off | guard m/h/l | ki guard %bar | push | lift | hitstop hit/guard | cancel |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| brawler_jab1 | light 1 | mid | 8 | 3 | 12 | 22 | 7.5 | 0.75 | stun 20 | +5 | 10 | -5 | - | PPP | - | 1.0 | 0.0 | 0/0 | 12-22 brawler_jab2 brawler_finisher_1 brawler_upper_hook brawler_sweep; super |
| brawler_jab2 | light 2 | mid | 5 | 3 | 15 | 22 | 7.5 | 0.75 | stun 20 | +2 | 10 | -8 | - | PPP | - | 1.0 | 0.0 | 0/0 | 11-22 brawler_hook brawler_finisher_2 brawler_upper_hook brawler_sweep; super |
| brawler_hook | light 3 | mid | 9 | 3 | 13 | 24 | 10.0 | 1.0 | stun 22 | +6 | 10 | -6 | - | PPP | - | 1.2 | 0.0 | 0/0 | 12-24 brawler_kick brawler_finisher_3 brawler_upper_hook brawler_sweep; super |
| brawler_kick | light 4 | mid | 14 | 4 | 9 | 26 | 11.3 | 1.13 | stun 26 | +13 | 10 | -3 | - | PPP | - | 1.5 | 0.0 | 0/0 | 21-26 brawler_ender brawler_finisher_4 brawler_upper_hook brawler_sweep; super |
| brawler_ender | light 5 | mid | 13 | 4 | 70 | 86 | 13.8 | 1.38 | stagger 34 | -40 | 14 | -60 | - | PPP | - | 7.0 | 0.0 | 0/0 | 14-41 brawler_finisher brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_1 |  | mid | 10 | 4 | 38 | 51 | 12.5 | 1.25 | stagger 30 | -12 | 18 | -24 | -2 | SKK | 45.0 | 1.0 | 0.0 | 8/0 | 13-31 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_1_charged |  | mid | 14 | 4 | 38 | 55 | 12.5 | 1.25 | stagger 30 | -12 | 18 | -24 | - | KKK | 45.0 | 12.0 | 5.0 | 8/0 | 16-34 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_1_charged @full |  | mid | 14 +45 held | 4 | 38 | 55 | 22.5 | 2.25 | KD | - | 18 | -24 | - | KKK | 63.0 | 12.0 | 5.0 | 8/0 | 16-34 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_2 |  | mid | 11 | 4 | 40 | 54 | 15.0 | 1.5 | stagger 28 | -16 | 18 | -26 | -2 | SKK | 45.0 | 5.5 | 0.0 | 8/0 | 13-31 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_2_charged |  | mid | 15 | 4 | 40 | 58 | 15.0 | 1.5 | stagger 28 | -16 | 18 | -26 | - | KKK | 45.0 | 12.0 | 5.0 | 8/0 | 17-35 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_2_charged @full |  | mid | 15 +45 held | 4 | 40 | 58 | 27.0 | 2.7 | KD | - | 18 | -26 | - | KKK | 63.0 | 12.0 | 5.0 | 8/0 | 17-35 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_3 |  | mid | 11 | 4 | 40 | 54 | 16.3 | 1.63 | stagger 36 | -8 | 18 | -26 | -2 | SKK | 45.0 | 1.5 | 0.0 | 8/0 | 13-31 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_3_charged |  | mid | 15 | 4 | 40 | 58 | 16.3 | 1.63 | stagger 36 | -8 | 18 | -26 | - | KKK | 45.0 | 12.0 | 5.0 | 8/0 | 17-35 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_3_charged @full |  | mid | 15 +45 held | 4 | 40 | 58 | 29.3 | 2.93 | KD | - | 18 | -26 | - | KKK | 63.0 | 12.0 | 5.0 | 8/0 | 17-35 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_4 |  | mid | 12 | 4 | 42 | 57 | 17.5 | 1.75 | stagger 42 | -4 | 18 | -28 | -2 | SKK | 45.0 | 1.0 | 0.0 | 8/0 | 13-31 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_4_charged |  | mid | 16 | 4 | 42 | 61 | 17.5 | 1.75 | stagger 42 | -4 | 18 | -28 | - | KKK | 45.0 | 12.0 | 5.0 | 8/0 | 18-36 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_4_charged @full |  | mid | 16 +45 held | 4 | 42 | 61 | 31.5 | 3.15 | KD | - | 18 | -28 | - | KKK | 63.0 | 12.0 | 5.0 | 8/0 | 18-36 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher | finisher | mid | 11 | 4 | 44 | 58 | 21.3 | 2.13 | KD | - | 18 | -30 | -2 | SKK | 45.0 | 9.0 | 6.0 | 8/0 | 13-31 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_charged |  | mid | 15 | 4 | 44 | 62 | 21.3 | 2.13 | KD | - | 18 | -30 | - | KKK | 45.0 | 12.0 | 5.0 | 8/0 | 17-35 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_finisher_charged @full |  | mid | 15 +45 held | 4 | 44 | 62 | 38.3 | 3.82 | KD | - | 18 | -30 | - | KKK | 63.0 | 12.0 | 5.0 | 8/0 | 17-35 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_upper_hook | heavy_high | high | 13 | 4 | 40 | 56 | 16.3 | 1.63 | KD | - | 18 | -26 | -2 | KOU | 45.0 | 0.6 | 8.5 | 8/0 | 14-37 brawler_jab1 (on hit); super |
| brawler_upper_hook_charged |  | high | 17 | 4 | 40 | 60 | 16.3 | 1.63 | KD | - | 18 | -26 | - | KKU | 45.0 | 0.6 | 10.5 | 8/0 | 19-37 brawler_jab1 (on hit); super |
| brawler_upper_hook_charged @full |  | high | 17 +45 held | 4 | 40 | 60 | 29.3 | 2.93 | KD | - | 18 | -26 | - | KKU | 63.0 | 0.6 | 10.5 | 8/0 | 19-37 brawler_jab1 (on hit); super |
| brawler_sweep | heavy_low | low | 14 | 4 | 42 | 59 | 15.0 | 1.5 | KD | - | 18 | -28 | -2 | KUO | 45.0 | 1.5 | 3.0 | 8/0 | 15-33 brawler_jab1 brawler_upper_hook (on hit); super |
| brawler_sweep_charged |  | low | 18 | 4 | 42 | 63 | 15.0 | 1.5 | KD | - | 18 | -28 | - | KUK | 45.0 | 3.0 | 4.0 | 8/0 | 20-38 brawler_jab1 brawler_upper_hook (on hit); super |
| brawler_sweep_charged @full |  | low | 18 +45 held | 4 | 42 | 63 | 27.0 | 2.7 | KD | - | 18 | -28 | - | KUK | 63.0 | 3.0 | 4.0 | 8/0 | 20-38 brawler_jab1 brawler_upper_hook (on hit); super |
| brawler_kick_mid | heavy | mid | 15 | 4 | 34 | 52 | 18.8 | 1.88 | stagger 36 | -2 | 20 | -18 | 0 | OKK | 45.0 | 2.5 | 0.0 | 8/0 | 17-35 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_charge_punch |  | mid | 19 | 4 | 44 | 66 | 13.8 | 1.38 | stun 26 | -22 | 16 | -32 | - | KKK | 40.0 | 13.0 | 4.0 | 8/0 | super |
| brawler_charge_punch @full |  | mid | 19 +45 held | 4 | 44 | 66 | 30.3 | 3.03 | KD | - | 16 | -32 | - | KKK | 56.0 | 13.0 | 4.0 | 8/0 | super |
| brawler_smash_up |  | high | 19 | 4 | 44 | 66 | 13.8 | 1.38 | stun 26 | -22 | 16 | -32 | - | KKU | 40.0 | 1.5 | 9.5 | 8/0 | super |
| brawler_smash_up @full |  | high | 19 +45 held | 4 | 44 | 66 | 30.3 | 3.03 | KD | - | 16 | -32 | - | KKU | 56.0 | 1.5 | 9.5 | 8/0 | super |
| brawler_smash_down |  | low | 19 | 4 | 44 | 66 | 13.8 | 1.38 | stun 26 | -22 | 16 | -32 | - | KUK | 40.0 | 3.0 | -4.0 | 8/0 | super |
| brawler_smash_down @full |  | low | 19 +45 held | 4 | 44 | 66 | 30.3 | 3.03 | KD | - | 16 | -32 | - | KUK | 56.0 | 3.0 | -4.0 | 8/0 | super |
| brawler_smash_left |  | mid | 19 | 4 | 44 | 66 | 13.8 | 1.38 | stun 26 | -22 | 16 | -32 | - | KKK | 40.0 | 3.0 | 2.5 | 8/0 | super |
| brawler_smash_left @full |  | mid | 19 +45 held | 4 | 44 | 66 | 30.3 | 3.03 | KD | - | 16 | -32 | - | KKK | 56.0 | 3.0 | 2.5 | 8/0 | super |
| brawler_smash_right |  | mid | 19 | 4 | 44 | 66 | 13.8 | 1.38 | stun 26 | -22 | 16 | -32 | - | KKK | 40.0 | 3.0 | 2.5 | 8/0 | super |
| brawler_smash_right @full |  | mid | 19 +45 held | 4 | 44 | 66 | 30.3 | 3.03 | KD | - | 16 | -32 | - | KKK | 56.0 | 3.0 | 2.5 | 8/0 | super |
| brawler_charge_kick |  | mid | 21 | 4 | 46 | 70 | 17.5 | 1.75 | stagger 36 | -14 | 20 | -30 | - | KKK | 40.0 | 6.0 | 0.0 | 8/0 | 25-45 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_charge_kick @full |  | mid | 21 +60 held | 4 | 46 | 70 | 35.0 | 3.5 | stagger 80 | +30 | 20 | -30 | - | KKK | 56.0 | 6.0 | 0.0 | 8/0 | 25-45 brawler_jab1 brawler_upper_hook brawler_sweep (on hit); super |
| brawler_jump_kick | jump_attack | mid | 7 | 8 | 10 | 24 | 12.5 | 1.25 | stun 24 | +6 | 12 | -6 | - | PPU | - | 3.0 | 0.0 | 0/0 |  |
| brawler_dive_kick | jump_heavy | mid | 9 | 12 | 12 | 32 | 16.3 | 1.63 | KD | - | 16 | -8 | - | KKU | 45.0 | 4.0 | 3.0 | 8/0 |  |
| brawler_duck_kick | duck_heavy | low | 7 | 4 | 18 | 28 | 13.8 | 1.38 | KD | - | 12 | -10 | -8 | KUO | 45.0 | 1.5 | 2.5 | 8/0 | super |
| brawler_getup_kick | getup_attack | low | 7 | 10 | 20 | 36 | 11.3 | 1.13 | KD | - | 12 | -18 | -8 | KUO | 45.0 | 4.0 | 3.0 | 8/0 |  |
| brawler_dash_punch | dash_attack | mid | 7 | 5 | 18 | 29 | 15.0 | 1.5 | KD | - | 14 | -9 | - | KKK | 45.0 | 6.0 | 3.0 | 8/0 |  |
| brawler_throw | throw | mid | 6 | 3 | 28 | 36 | 22.5 | 2.25 | KD | - | - | - | - | throw | - | 5.5 | 5.0 | 8/0 |  |
| brawler_counter | counter | mid | 4 | 4 | 22 | 29 | 17.5 | 1.75 | KD | - | 16 | -10 | -4 | OKK | 45.0 | 3.0 | 7.0 | 8/0 | super |
| brawler_ki_blast | ki_blast | mid | shot 9 | 0 | 16 | 24 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| brawler_ki_blast_shot | shot of brawler_ki_blast | mid | - | - | - | - | 6.3 | 0.63 | stun 16 | - | 8 | - | - | PPP | - | 2.0 | 0.0 | 3/0 | - |
| brawler_ki_blast_charged |  | mid | shot 11 | 0 | 20 | 30 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| brawler_ki_blast_charged @full |  | mid | shot 11 +30 held | 0 | 20 | 30 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| brawler_ki_blast_charged_shot | shot of brawler_ki_blast_charged | mid | - | - | - | - | 15.0 | 1.5 | KD | - | 14 | - | - | KKK | 45.0 | 6.0 | 4.0 | 8/0 | - |
| brawler_rush | super1 | mid | 9 | 6 | 30 | 44 | 10.0 | 1.0 | stun 40 | chain | 12 | -24 | - | KKK | 100.0 | 0.5 | 0.0 | 3/0 | auto brawler_rush_2 on hit |
| brawler_rush_2 |  | mid | 4 | 2 | 6 | 11 | 8.8 | 0.88 | stun 30 | chain | 12 | +4 | - | KKK | 15.0 | 0.5 | 0.0 | 3/0 | auto brawler_rush_3 on hit |
| brawler_rush_3 |  | mid | 4 | 2 | 6 | 11 | 8.8 | 0.88 | stun 30 | chain | 12 | +4 | - | KKK | 15.0 | 0.5 | 0.0 | 3/0 | auto brawler_rush_4 on hit |
| brawler_rush_4 |  | mid | 4 | 2 | 6 | 11 | 8.8 | 0.88 | stun 30 | chain | 12 | +4 | - | KKK | 15.0 | 0.5 | 0.0 | 3/0 | auto brawler_rush_finish on hit |
| brawler_rush_finish |  | mid | 7 | 3 | 28 | 37 | 30.0 | 3.0 | KD | - | 12 | -19 | - | KKK | 15.0 | 9.0 | 8.0 | 14/0 |  |
| brawler_beam | super2 | mid | shot 19 | 0 | 80 | 98 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| brawler_beam_shot | shot of brawler_beam | mid | - | - | - | - | 4.5 | 0.45 | stun 18 | - | 12 | - | - | KKK | 12.0 | 1.0 | 0.0 | 1/0 | - |
| brawler_ultimate | ultimate | mid | shot 31 | 0 | 120 | 150 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| brawler_ultimate_shot | shot of brawler_ultimate | mid | - | - | - | - | 5.5 | 0.55 | stun 18 | - | 14 | - | - | KKK | 25.0 | 1.0 | 0.0 | 1/0 | - |

### Titan

| move | role | height | hit on | active | recovery | total | damage | dmg % | on hit | adv hit | guard stun | adv guard | adv push-off | guard m/h/l | ki guard %bar | push | lift | hitstop hit/guard | cancel |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| titan_jab1 | light 1 | mid | 10 | 3 | 16 | 28 | 9.8 | 0.98 | stun 20 | +1 | 10 | -9 | - | PPP | - | 1.0 | 0.0 | 0/0 | 15-28 titan_jab2 titan_finisher_1 titan_upper_hook titan_sweep; super |
| titan_jab2 | light 2 | mid | 6 | 3 | 20 | 28 | 9.8 | 0.98 | stun 20 | -3 | 10 | -13 | - | PPP | - | 1.0 | 0.0 | 0/0 | 14-28 titan_hook titan_finisher_2 titan_upper_hook titan_sweep; super |
| titan_hook | light 3 | mid | 11 | 3 | 17 | 30 | 13.0 | 1.3 | stun 22 | +2 | 10 | -10 | - | PPP | - | 1.2 | 0.0 | 0/0 | 15-31 titan_kick titan_finisher_3 titan_upper_hook titan_sweep; super |
| titan_kick | light 4 | mid | 18 | 4 | 12 | 33 | 14.6 | 1.46 | stun 26 | +10 | 10 | -6 | - | PPP | - | 1.5 | 0.0 | 0/0 | 27-34 titan_ender titan_finisher_4 titan_upper_hook titan_sweep; super |
| titan_ender | light 5 | mid | 17 | 4 | 91 | 111 | 17.9 | 1.79 | stagger 34 | -61 | 14 | -81 | - | PPP | - | 7.0 | 0.0 | 0/0 | 18-53 titan_finisher titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_1 |  | mid | 13 | 4 | 49 | 65 | 16.3 | 1.63 | stagger 30 | -23 | 18 | -35 | -2 | SKK | 51.7 | 1.0 | 0.0 | 8/0 | 17-40 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_1_charged |  | mid | 18 | 4 | 49 | 70 | 16.3 | 1.63 | stagger 30 | -23 | 18 | -35 | - | KKK | 51.7 | 12.0 | 5.0 | 8/0 | 21-44 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_1_charged @full |  | mid | 18 +45 held | 4 | 49 | 70 | 29.3 | 2.93 | KD | - | 18 | -35 | - | KKK | 72.4 | 12.0 | 5.0 | 8/0 | 21-44 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_2 |  | mid | 14 | 4 | 52 | 69 | 19.5 | 1.95 | stagger 28 | -28 | 18 | -38 | -2 | SKK | 51.7 | 5.5 | 0.0 | 8/0 | 17-40 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_2_charged |  | mid | 19 | 4 | 52 | 74 | 19.5 | 1.95 | stagger 28 | -28 | 18 | -38 | - | KKK | 51.7 | 12.0 | 5.0 | 8/0 | 22-45 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_2_charged @full |  | mid | 19 +45 held | 4 | 52 | 74 | 35.1 | 3.51 | KD | - | 18 | -38 | - | KKK | 72.4 | 12.0 | 5.0 | 8/0 | 22-45 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_3 |  | mid | 14 | 4 | 52 | 69 | 21.1 | 2.11 | stagger 36 | -20 | 18 | -38 | -2 | SKK | 51.7 | 1.5 | 0.0 | 8/0 | 17-40 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_3_charged |  | mid | 19 | 4 | 52 | 74 | 21.1 | 2.11 | stagger 36 | -20 | 18 | -38 | - | KKK | 51.7 | 12.0 | 5.0 | 8/0 | 22-45 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_3_charged @full |  | mid | 19 +45 held | 4 | 52 | 74 | 38.0 | 3.8 | KD | - | 18 | -38 | - | KKK | 72.4 | 12.0 | 5.0 | 8/0 | 22-45 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_4 |  | mid | 15 | 4 | 55 | 73 | 22.8 | 2.28 | stagger 42 | -17 | 18 | -41 | -2 | SKK | 51.7 | 1.0 | 0.0 | 8/0 | 17-40 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_4_charged |  | mid | 21 | 4 | 55 | 79 | 22.8 | 2.28 | stagger 42 | -17 | 18 | -41 | - | KKK | 51.7 | 12.0 | 5.0 | 8/0 | 23-47 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_4_charged @full |  | mid | 21 +45 held | 4 | 55 | 79 | 41.0 | 4.09 | KD | - | 18 | -41 | - | KKK | 72.4 | 12.0 | 5.0 | 8/0 | 23-47 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher | finisher | mid | 14 | 4 | 57 | 74 | 27.6 | 2.76 | KD | - | 18 | -43 | -2 | SKK | 51.7 | 9.0 | 6.0 | 8/0 | 17-40 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_charged |  | mid | 19 | 4 | 57 | 79 | 27.6 | 2.76 | KD | - | 18 | -43 | - | KKK | 51.7 | 12.0 | 5.0 | 8/0 | 22-45 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_finisher_charged @full |  | mid | 19 +45 held | 4 | 57 | 79 | 49.7 | 4.97 | KD | - | 18 | -43 | - | KKK | 72.4 | 12.0 | 5.0 | 8/0 | 22-45 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_upper_hook | heavy_high | high | 17 | 4 | 52 | 72 | 21.1 | 2.11 | KD | - | 18 | -38 | -2 | KOU | 51.7 | 0.6 | 8.5 | 8/0 | 18-48 titan_jab1 (on hit); super |
| titan_upper_hook_charged |  | high | 22 | 4 | 52 | 77 | 21.1 | 2.11 | KD | - | 18 | -38 | - | KKU | 51.7 | 0.6 | 10.5 | 8/0 | 24-48 titan_jab1 (on hit); super |
| titan_upper_hook_charged @full |  | high | 22 +45 held | 4 | 52 | 77 | 38.0 | 3.8 | KD | - | 18 | -38 | - | KKU | 72.4 | 0.6 | 10.5 | 8/0 | 24-48 titan_jab1 (on hit); super |
| titan_sweep | heavy_low | low | 18 | 4 | 55 | 76 | 19.5 | 1.95 | KD | - | 18 | -41 | -2 | KUO | 51.7 | 1.5 | 3.0 | 8/0 | 19-43 titan_jab1 titan_upper_hook (on hit); super |
| titan_sweep_charged |  | low | 23 | 4 | 55 | 81 | 19.5 | 1.95 | KD | - | 18 | -41 | - | KUK | 51.7 | 3.0 | 4.0 | 8/0 | 26-49 titan_jab1 titan_upper_hook (on hit); super |
| titan_sweep_charged @full |  | low | 23 +45 held | 4 | 55 | 81 | 35.1 | 3.51 | KD | - | 18 | -41 | - | KUK | 72.4 | 3.0 | 4.0 | 8/0 | 26-49 titan_jab1 titan_upper_hook (on hit); super |
| titan_kick_mid | heavy | mid | 19 | 4 | 44 | 66 | 24.4 | 2.44 | stagger 36 | -12 | 20 | -28 | 0 | OKK | 51.7 | 2.5 | 0.0 | 8/0 | 22-45 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_charge_punch |  | mid | 24 | 4 | 57 | 84 | 17.9 | 1.79 | stun 26 | -35 | 16 | -45 | - | KKK | 46.0 | 13.0 | 4.0 | 8/0 | super |
| titan_charge_punch @full |  | mid | 24 +45 held | 4 | 57 | 84 | 39.3 | 3.93 | KD | - | 16 | -45 | - | KKK | 64.4 | 13.0 | 4.0 | 8/0 | super |
| titan_smash_up |  | high | 24 | 4 | 57 | 84 | 17.9 | 1.79 | stun 26 | -35 | 16 | -45 | - | KKU | 46.0 | 1.5 | 9.5 | 8/0 | super |
| titan_smash_up @full |  | high | 24 +45 held | 4 | 57 | 84 | 39.3 | 3.93 | KD | - | 16 | -45 | - | KKU | 64.4 | 1.5 | 9.5 | 8/0 | super |
| titan_smash_down |  | low | 24 | 4 | 57 | 84 | 17.9 | 1.79 | stun 26 | -35 | 16 | -45 | - | KUK | 46.0 | 3.0 | -4.0 | 8/0 | super |
| titan_smash_down @full |  | low | 24 +45 held | 4 | 57 | 84 | 39.3 | 3.93 | KD | - | 16 | -45 | - | KUK | 64.4 | 3.0 | -4.0 | 8/0 | super |
| titan_smash_left |  | mid | 24 | 4 | 57 | 84 | 17.9 | 1.79 | stun 26 | -35 | 16 | -45 | - | KKK | 46.0 | 3.0 | 2.5 | 8/0 | super |
| titan_smash_left @full |  | mid | 24 +45 held | 4 | 57 | 84 | 39.3 | 3.93 | KD | - | 16 | -45 | - | KKK | 64.4 | 3.0 | 2.5 | 8/0 | super |
| titan_smash_right |  | mid | 24 | 4 | 57 | 84 | 17.9 | 1.79 | stun 26 | -35 | 16 | -45 | - | KKK | 46.0 | 3.0 | 2.5 | 8/0 | super |
| titan_smash_right @full |  | mid | 24 +45 held | 4 | 57 | 84 | 39.3 | 3.93 | KD | - | 16 | -45 | - | KKK | 64.4 | 3.0 | 2.5 | 8/0 | super |
| titan_charge_kick |  | mid | 27 | 4 | 60 | 90 | 22.8 | 2.28 | stagger 36 | -28 | 20 | -44 | - | KKK | 46.0 | 6.0 | 0.0 | 8/0 | 32-58 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_charge_kick @full |  | mid | 27 +60 held | 4 | 60 | 90 | 45.5 | 4.55 | stagger 80 | +16 | 20 | -44 | - | KKK | 64.4 | 6.0 | 0.0 | 8/0 | 32-58 titan_jab1 titan_upper_hook titan_sweep (on hit); super |
| titan_jump_kick | jump_attack | mid | 9 | 8 | 13 | 29 | 16.3 | 1.63 | stun 24 | +3 | 12 | -9 | - | PPU | - | 3.0 | 0.0 | 0/0 |  |
| titan_dive_kick | jump_heavy | mid | 11 | 12 | 16 | 38 | 21.1 | 2.11 | KD | - | 16 | -12 | - | KKU | 51.7 | 4.0 | 3.0 | 8/0 |  |
| titan_duck_kick | duck_heavy | low | 9 | 4 | 23 | 35 | 17.9 | 1.79 | KD | - | 12 | -15 | -8 | KUO | 51.7 | 1.5 | 2.5 | 8/0 | super |
| titan_getup_kick | getup_attack | low | 9 | 10 | 26 | 44 | 14.6 | 1.46 | KD | - | 12 | -24 | -8 | KUO | 51.7 | 4.0 | 3.0 | 8/0 |  |
| titan_dash_punch | dash_attack | mid | 9 | 5 | 23 | 36 | 19.5 | 1.95 | KD | - | 14 | -14 | - | KKK | 51.7 | 6.0 | 3.0 | 8/0 |  |
| titan_throw | throw | mid | 8 | 3 | 36 | 46 | 29.3 | 2.93 | KD | - | - | - | - | throw | - | 5.5 | 5.0 | 8/0 |  |
| titan_counter | counter | mid | 5 | 4 | 29 | 37 | 22.8 | 2.28 | KD | - | 16 | -17 | -4 | OKK | 51.7 | 3.0 | 7.0 | 8/0 | super |
| titan_ki_blast | ki_blast | mid | shot 11 | 0 | 21 | 31 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| titan_ki_blast_shot | shot of titan_ki_blast | mid | - | - | - | - | 8.1 | 0.81 | stun 16 | - | 8 | - | - | PPP | - | 2.0 | 0.0 | 3/0 | - |
| titan_ki_blast_charged |  | mid | shot 14 | 0 | 26 | 39 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| titan_ki_blast_charged @full |  | mid | shot 14 +30 held | 0 | 26 | 39 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| titan_ki_blast_charged_shot | shot of titan_ki_blast_charged | mid | - | - | - | - | 19.5 | 1.95 | KD | - | 14 | - | - | KKK | 51.7 | 6.0 | 4.0 | 8/0 | - |
| titan_rush | super1 | mid | 11 | 6 | 39 | 55 | 13.0 | 1.3 | stun 40 | chain | 12 | -33 | - | KKK | 115.0 | 0.5 | 0.0 | 3/0 | auto titan_rush_2 on hit |
| titan_rush_2 |  | mid | 5 | 2 | 8 | 14 | 11.4 | 1.14 | stun 30 | chain | 12 | +2 | - | KKK | 17.3 | 0.5 | 0.0 | 3/0 | auto titan_rush_3 on hit |
| titan_rush_3 |  | mid | 5 | 2 | 8 | 14 | 11.4 | 1.14 | stun 30 | chain | 12 | +2 | - | KKK | 17.3 | 0.5 | 0.0 | 3/0 | auto titan_rush_4 on hit |
| titan_rush_4 |  | mid | 5 | 2 | 8 | 14 | 11.4 | 1.14 | stun 30 | chain | 12 | +2 | - | KKK | 17.3 | 0.5 | 0.0 | 3/0 | auto titan_rush_finish on hit |
| titan_rush_finish |  | mid | 9 | 3 | 36 | 47 | 39.0 | 3.9 | KD | - | 12 | -27 | - | KKK | 17.3 | 9.0 | 8.0 | 14/0 |  |
| titan_beam | super2 | mid | shot 24 | 0 | 104 | 127 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| titan_beam_shot | shot of titan_beam | mid | - | - | - | - | 5.9 | 0.58 | stun 18 | - | 12 | - | - | KKK | 13.8 | 1.0 | 0.0 | 1/0 | - |
| titan_ultimate | ultimate | mid | shot 40 | 0 | 156 | 195 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| titan_ultimate_shot | shot of titan_ultimate | mid | - | - | - | - | 7.2 | 0.72 | stun 18 | - | 14 | - | - | KKK | 28.7 | 1.0 | 0.0 | 1/0 | - |

### Bulk

| move | role | height | hit on | active | recovery | total | damage | dmg % | on hit | adv hit | guard stun | adv guard | adv push-off | guard m/h/l | ki guard %bar | push | lift | hitstop hit/guard | cancel |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bulk_jab1 | light 1 | mid | 9 | 3 | 14 | 25 | 7.5 | 0.75 | stun 20 | +3 | 10 | -7 | - | PPP | - | 1.0 | 0.0 | 0/0 | 14-26 bulk_jab2 bulk_finisher_1 bulk_upper_hook bulk_sweep; super |
| bulk_jab2 | light 2 | mid | 6 | 3 | 18 | 26 | 7.5 | 0.75 | stun 20 | -1 | 10 | -11 | - | PPP | - | 1.0 | 0.0 | 0/0 | 13-26 bulk_hook bulk_finisher_2 bulk_upper_hook bulk_sweep; super |
| bulk_hook | light 3 | mid | 10 | 3 | 15 | 27 | 10.0 | 1.0 | stun 22 | +4 | 10 | -8 | - | PPP | - | 1.2 | 0.0 | 0/0 | 14-28 bulk_kick bulk_finisher_3 bulk_upper_hook bulk_sweep; super |
| bulk_kick | light 4 | mid | 16 | 4 | 11 | 30 | 11.3 | 1.13 | stun 26 | +11 | 10 | -5 | - | PPP | - | 1.5 | 0.0 | 0/0 | 25-31 bulk_ender bulk_finisher_4 bulk_upper_hook bulk_sweep; super |
| bulk_ender | light 5 | mid | 15 | 4 | 83 | 101 | 13.8 | 1.38 | stagger 34 | -53 | 14 | -73 | - | PPP | - | 7.0 | 0.0 | 0/0 | 16-48 bulk_finisher bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_1 |  | mid | 12 | 4 | 45 | 60 | 12.5 | 1.25 | stagger 30 | -19 | 18 | -31 | -2 | SKK | 49.5 | 1.0 | 0.0 | 8/0 | 15-36 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_1_charged |  | mid | 16 | 4 | 45 | 64 | 12.5 | 1.25 | stagger 30 | -19 | 18 | -31 | - | KKK | 49.5 | 12.0 | 5.0 | 8/0 | 19-40 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_1_charged @full |  | mid | 16 +45 held | 4 | 45 | 64 | 22.5 | 2.25 | KD | - | 18 | -31 | - | KKK | 69.3 | 12.0 | 5.0 | 8/0 | 19-40 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_2 |  | mid | 13 | 4 | 47 | 63 | 15.0 | 1.5 | stagger 28 | -23 | 18 | -33 | -2 | SKK | 49.5 | 5.5 | 0.0 | 8/0 | 15-36 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_2_charged |  | mid | 18 | 4 | 47 | 68 | 15.0 | 1.5 | stagger 28 | -23 | 18 | -33 | - | KKK | 49.5 | 12.0 | 5.0 | 8/0 | 20-41 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_2_charged @full |  | mid | 18 +45 held | 4 | 47 | 68 | 27.0 | 2.7 | KD | - | 18 | -33 | - | KKK | 69.3 | 12.0 | 5.0 | 8/0 | 20-41 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_3 |  | mid | 13 | 4 | 47 | 63 | 16.3 | 1.63 | stagger 36 | -15 | 18 | -33 | -2 | SKK | 49.5 | 1.5 | 0.0 | 8/0 | 15-36 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_3_charged |  | mid | 18 | 4 | 47 | 68 | 16.3 | 1.63 | stagger 36 | -15 | 18 | -33 | - | KKK | 49.5 | 12.0 | 5.0 | 8/0 | 20-41 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_3_charged @full |  | mid | 18 +45 held | 4 | 47 | 68 | 29.3 | 2.93 | KD | - | 18 | -33 | - | KKK | 69.3 | 12.0 | 5.0 | 8/0 | 20-41 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_4 |  | mid | 14 | 4 | 50 | 67 | 17.5 | 1.75 | stagger 42 | -12 | 18 | -36 | -2 | SKK | 49.5 | 1.0 | 0.0 | 8/0 | 15-36 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_4_charged |  | mid | 19 | 4 | 50 | 72 | 17.5 | 1.75 | stagger 42 | -12 | 18 | -36 | - | KKK | 49.5 | 12.0 | 5.0 | 8/0 | 21-42 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_4_charged @full |  | mid | 19 +45 held | 4 | 50 | 72 | 31.5 | 3.15 | KD | - | 18 | -36 | - | KKK | 69.3 | 12.0 | 5.0 | 8/0 | 21-42 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher | finisher | mid | 13 | 4 | 52 | 68 | 21.3 | 2.13 | KD | - | 18 | -38 | -2 | SKK | 49.5 | 9.0 | 6.0 | 8/0 | 15-36 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_charged |  | mid | 18 | 4 | 52 | 73 | 21.3 | 2.13 | KD | - | 18 | -38 | - | KKK | 49.5 | 12.0 | 5.0 | 8/0 | 20-41 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_finisher_charged @full |  | mid | 18 +45 held | 4 | 52 | 73 | 38.3 | 3.82 | KD | - | 18 | -38 | - | KKK | 69.3 | 12.0 | 5.0 | 8/0 | 20-41 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_upper_hook | heavy_high | high | 15 | 4 | 47 | 65 | 16.3 | 1.63 | KD | - | 18 | -33 | -2 | KOU | 49.5 | 0.6 | 8.5 | 8/0 | 16-43 bulk_jab1 (on hit); super |
| bulk_upper_hook_charged |  | high | 20 | 4 | 47 | 70 | 16.3 | 1.63 | KD | - | 18 | -33 | - | KKU | 49.5 | 0.6 | 10.5 | 8/0 | 22-43 bulk_jab1 (on hit); super |
| bulk_upper_hook_charged @full |  | high | 20 +45 held | 4 | 47 | 70 | 29.3 | 2.93 | KD | - | 18 | -33 | - | KKU | 69.3 | 0.6 | 10.5 | 8/0 | 22-43 bulk_jab1 (on hit); super |
| bulk_sweep | heavy_low | low | 16 | 4 | 50 | 69 | 15.0 | 1.5 | KD | - | 18 | -36 | -2 | KUO | 49.5 | 1.5 | 3.0 | 8/0 | 18-39 bulk_jab1 bulk_upper_hook (on hit); super |
| bulk_sweep_charged |  | low | 21 | 4 | 50 | 74 | 15.0 | 1.5 | KD | - | 18 | -36 | - | KUK | 49.5 | 3.0 | 4.0 | 8/0 | 23-45 bulk_jab1 bulk_upper_hook (on hit); super |
| bulk_sweep_charged @full |  | low | 21 +45 held | 4 | 50 | 74 | 27.0 | 2.7 | KD | - | 18 | -36 | - | KUK | 69.3 | 3.0 | 4.0 | 8/0 | 23-45 bulk_jab1 bulk_upper_hook (on hit); super |
| bulk_kick_mid | heavy | mid | 18 | 4 | 40 | 61 | 18.8 | 1.88 | stagger 36 | -8 | 20 | -24 | 0 | OKK | 49.5 | 2.5 | 0.0 | 8/0 | 20-41 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_charge_punch |  | mid | 22 | 4 | 52 | 77 | 13.8 | 1.38 | stun 26 | -30 | 16 | -40 | - | KKK | 44.0 | 13.0 | 4.0 | 8/0 | super |
| bulk_charge_punch @full |  | mid | 22 +45 held | 4 | 52 | 77 | 30.3 | 3.03 | KD | - | 16 | -40 | - | KKK | 61.6 | 13.0 | 4.0 | 8/0 | super |
| bulk_smash_up |  | high | 22 | 4 | 52 | 77 | 13.8 | 1.38 | stun 26 | -30 | 16 | -40 | - | KKU | 44.0 | 1.5 | 9.5 | 8/0 | super |
| bulk_smash_up @full |  | high | 22 +45 held | 4 | 52 | 77 | 30.3 | 3.03 | KD | - | 16 | -40 | - | KKU | 61.6 | 1.5 | 9.5 | 8/0 | super |
| bulk_smash_down |  | low | 22 | 4 | 52 | 77 | 13.8 | 1.38 | stun 26 | -30 | 16 | -40 | - | KUK | 44.0 | 3.0 | -4.0 | 8/0 | super |
| bulk_smash_down @full |  | low | 22 +45 held | 4 | 52 | 77 | 30.3 | 3.03 | KD | - | 16 | -40 | - | KUK | 61.6 | 3.0 | -4.0 | 8/0 | super |
| bulk_smash_left |  | mid | 22 | 4 | 52 | 77 | 13.8 | 1.38 | stun 26 | -30 | 16 | -40 | - | KKK | 44.0 | 3.0 | 2.5 | 8/0 | super |
| bulk_smash_left @full |  | mid | 22 +45 held | 4 | 52 | 77 | 30.3 | 3.03 | KD | - | 16 | -40 | - | KKK | 61.6 | 3.0 | 2.5 | 8/0 | super |
| bulk_smash_right |  | mid | 22 | 4 | 52 | 77 | 13.8 | 1.38 | stun 26 | -30 | 16 | -40 | - | KKK | 44.0 | 3.0 | 2.5 | 8/0 | super |
| bulk_smash_right @full |  | mid | 22 +45 held | 4 | 52 | 77 | 30.3 | 3.03 | KD | - | 16 | -40 | - | KKK | 61.6 | 3.0 | 2.5 | 8/0 | super |
| bulk_charge_kick |  | mid | 25 | 4 | 54 | 82 | 17.5 | 1.75 | stagger 36 | -22 | 20 | -38 | - | KKK | 44.0 | 6.0 | 0.0 | 8/0 | 29-53 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_charge_kick @full |  | mid | 25 +60 held | 4 | 54 | 82 | 35.0 | 3.5 | stagger 80 | +22 | 20 | -38 | - | KKK | 61.6 | 6.0 | 0.0 | 8/0 | 29-53 bulk_jab1 bulk_upper_hook bulk_sweep (on hit); super |
| bulk_jump_kick | jump_attack | mid | 8 | 8 | 12 | 27 | 12.5 | 1.25 | stun 24 | +4 | 12 | -8 | - | PPU | - | 3.0 | 0.0 | 0/0 |  |
| bulk_dive_kick | jump_heavy | mid | 10 | 12 | 14 | 35 | 16.3 | 1.63 | KD | - | 16 | -10 | - | KKU | 49.5 | 4.0 | 3.0 | 8/0 |  |
| bulk_duck_kick | duck_heavy | low | 8 | 4 | 21 | 32 | 13.8 | 1.38 | KD | - | 12 | -13 | -8 | KUO | 49.5 | 1.5 | 2.5 | 8/0 | super |
| bulk_getup_kick | getup_attack | low | 8 | 10 | 24 | 41 | 11.3 | 1.13 | KD | - | 12 | -22 | -8 | KUO | 49.5 | 4.0 | 3.0 | 8/0 |  |
| bulk_dash_punch | dash_attack | mid | 8 | 5 | 21 | 33 | 15.0 | 1.5 | KD | - | 14 | -12 | - | KKK | 49.5 | 8.0 | 3.5 | 8/0 |  |
| bulk_throw | throw | mid | 7 | 3 | 33 | 42 | 32.5 | 3.25 | KD | - | - | - | - | throw | - | 5.5 | 5.0 | 8/0 |  |
| bulk_counter | counter | mid | 5 | 4 | 26 | 34 | 17.5 | 1.75 | KD | - | 16 | -14 | -4 | OKK | 49.5 | 3.0 | 7.0 | 8/0 | super |
| bulk_ki_blast | ki_blast | mid | shot 10 | 0 | 19 | 28 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| bulk_ki_blast_shot | shot of bulk_ki_blast | mid | - | - | - | - | 6.3 | 0.63 | stun 16 | - | 8 | - | - | PPP | - | 2.0 | 0.0 | 3/0 | - |
| bulk_ki_blast_charged |  | mid | shot 13 | 0 | 24 | 36 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| bulk_ki_blast_charged @full |  | mid | shot 13 +30 held | 0 | 24 | 36 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| bulk_ki_blast_charged_shot | shot of bulk_ki_blast_charged | mid | - | - | - | - | 15.0 | 1.5 | KD | - | 14 | - | - | KKK | 49.5 | 6.0 | 4.0 | 8/0 | - |
| bulk_rush | super1 | mid | 10 | 6 | 35 | 50 | 10.0 | 1.0 | stun 40 | chain | 12 | -29 | - | KKK | 110.0 | 0.5 | 0.0 | 3/0 | auto bulk_rush_2 on hit |
| bulk_rush_2 |  | mid | 5 | 2 | 7 | 13 | 8.8 | 0.88 | stun 30 | chain | 12 | +3 | - | KKK | 16.5 | 0.5 | 0.0 | 3/0 | auto bulk_rush_3 on hit |
| bulk_rush_3 |  | mid | 5 | 2 | 7 | 13 | 8.8 | 0.88 | stun 30 | chain | 12 | +3 | - | KKK | 16.5 | 0.5 | 0.0 | 3/0 | auto bulk_rush_4 on hit |
| bulk_rush_4 |  | mid | 5 | 2 | 7 | 13 | 8.8 | 0.88 | stun 30 | chain | 12 | +3 | - | KKK | 16.5 | 0.5 | 0.0 | 3/0 | auto bulk_rush_finish on hit |
| bulk_rush_finish |  | mid | 8 | 3 | 33 | 43 | 30.0 | 3.0 | KD | - | 12 | -24 | - | KKK | 16.5 | 9.0 | 8.0 | 14/0 |  |
| bulk_beam | super2 | mid | shot 22 | 0 | 94 | 115 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| bulk_beam_shot | shot of bulk_beam | mid | - | - | - | - | 4.5 | 0.45 | stun 18 | - | 12 | - | - | KKK | 13.2 | 1.0 | 0.0 | 1/0 | - |
| bulk_ultimate | ultimate | mid | shot 36 | 0 | 142 | 177 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| bulk_ultimate_shot | shot of bulk_ultimate | mid | - | - | - | - | 5.5 | 0.55 | stun 18 | - | 14 | - | - | KKK | 27.5 | 1.0 | 0.0 | 1/0 | - |

### Sprite

| move | role | height | hit on | active | recovery | total | damage | dmg % | on hit | adv hit | guard stun | adv guard | adv push-off | guard m/h/l | ki guard %bar | push | lift | hitstop hit/guard | cancel |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| sprite_jab1 | light 1 | mid | 7 | 3 | 10 | 19 | 6.3 | 0.63 | stun 20 | +7 | 10 | -3 | - | PPP | - | 1.0 | 0.0 | 0/0 | 10-18 sprite_jab2 sprite_finisher_1 sprite_upper_hook sprite_sweep; super |
| sprite_jab2 | light 2 | mid | 4 | 3 | 12 | 18 | 6.3 | 0.63 | stun 20 | +5 | 10 | -5 | - | PPP | - | 1.0 | 0.0 | 0/0 | 9-18 sprite_hook sprite_finisher_2 sprite_upper_hook sprite_sweep; super |
| sprite_hook | light 3 | mid | 7 | 3 | 10 | 19 | 8.4 | 0.84 | stun 22 | +9 | 10 | -3 | - | PPP | - | 1.2 | 0.0 | 0/0 | 10-19 sprite_kick sprite_finisher_3 sprite_upper_hook sprite_sweep; super |
| sprite_kick | light 4 | mid | 11 | 4 | 7 | 21 | 9.4 | 0.95 | stun 26 | +15 | 10 | -1 | - | PPP | - | 1.5 | 0.0 | 0/0 | 17-21 sprite_ender sprite_finisher_4 sprite_upper_hook sprite_sweep; super |
| sprite_ender | light 5 | mid | 11 | 4 | 56 | 70 | 11.6 | 1.16 | stagger 34 | -26 | 14 | -46 | - | PPP | - | 7.0 | 0.0 | 0/0 | 12-33 sprite_finisher sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_1 |  | mid | 8 | 4 | 30 | 41 | 10.5 | 1.05 | stagger 30 | -4 | 18 | -16 | -2 | SKK | 38.3 | 1.0 | 0.0 | 8/0 | 11-25 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_1_charged |  | mid | 11 | 4 | 30 | 44 | 10.5 | 1.05 | stagger 30 | -4 | 18 | -16 | - | KKK | 38.3 | 12.0 | 5.0 | 8/0 | 13-27 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_1_charged @full |  | mid | 11 +45 held | 4 | 30 | 44 | 18.9 | 1.89 | KD | - | 18 | -16 | - | KKK | 53.5 | 12.0 | 5.0 | 8/0 | 13-27 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_2 |  | mid | 9 | 4 | 32 | 44 | 12.6 | 1.26 | stagger 28 | -8 | 18 | -18 | -2 | SKK | 38.3 | 5.5 | 0.0 | 8/0 | 11-25 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_2_charged |  | mid | 12 | 4 | 32 | 47 | 12.6 | 1.26 | stagger 28 | -8 | 18 | -18 | - | KKK | 38.3 | 12.0 | 5.0 | 8/0 | 14-28 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_2_charged @full |  | mid | 12 +45 held | 4 | 32 | 47 | 22.7 | 2.27 | KD | - | 18 | -18 | - | KKK | 53.5 | 12.0 | 5.0 | 8/0 | 14-28 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_3 |  | mid | 9 | 4 | 32 | 44 | 13.7 | 1.37 | stagger 36 | 0 | 18 | -18 | -2 | SKK | 38.3 | 1.5 | 0.0 | 8/0 | 11-25 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_3_charged |  | mid | 12 | 4 | 32 | 47 | 13.7 | 1.37 | stagger 36 | 0 | 18 | -18 | - | KKK | 38.3 | 12.0 | 5.0 | 8/0 | 14-28 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_3_charged @full |  | mid | 12 +45 held | 4 | 32 | 47 | 24.6 | 2.46 | KD | - | 18 | -18 | - | KKK | 53.5 | 12.0 | 5.0 | 8/0 | 14-28 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_4 |  | mid | 10 | 4 | 34 | 47 | 14.7 | 1.47 | stagger 42 | +4 | 18 | -20 | -2 | SKK | 38.3 | 1.0 | 0.0 | 8/0 | 11-25 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_4_charged |  | mid | 13 | 4 | 34 | 50 | 14.7 | 1.47 | stagger 42 | +4 | 18 | -20 | - | KKK | 38.3 | 12.0 | 5.0 | 8/0 | 15-29 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_4_charged @full |  | mid | 13 +45 held | 4 | 34 | 50 | 26.5 | 2.65 | KD | - | 18 | -20 | - | KKK | 53.5 | 12.0 | 5.0 | 8/0 | 15-29 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher | finisher | mid | 9 | 4 | 35 | 47 | 17.8 | 1.78 | KD | - | 18 | -21 | -2 | SKK | 38.3 | 9.0 | 6.0 | 8/0 | 11-25 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_charged |  | mid | 12 | 4 | 35 | 50 | 17.8 | 1.78 | KD | - | 18 | -21 | - | KKK | 38.3 | 12.0 | 5.0 | 8/0 | 14-28 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_finisher_charged @full |  | mid | 12 +45 held | 4 | 35 | 50 | 32.1 | 3.21 | KD | - | 18 | -21 | - | KKK | 53.5 | 12.0 | 5.0 | 8/0 | 14-28 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_upper_hook | heavy_high | high | 11 | 4 | 32 | 46 | 13.7 | 1.37 | KD | - | 18 | -18 | -2 | KOU | 38.3 | 0.6 | 8.5 | 8/0 | 12-30 sprite_jab1 (on hit); super |
| sprite_upper_hook_charged |  | high | 14 | 4 | 32 | 49 | 13.7 | 1.37 | KD | - | 18 | -18 | - | KKU | 38.3 | 0.6 | 10.5 | 8/0 | 15-30 sprite_jab1 (on hit); super |
| sprite_upper_hook_charged @full |  | high | 14 +45 held | 4 | 32 | 49 | 24.6 | 2.46 | KD | - | 18 | -18 | - | KKU | 53.5 | 0.6 | 10.5 | 8/0 | 15-30 sprite_jab1 (on hit); super |
| sprite_sweep | heavy_low | low | 11 | 4 | 34 | 48 | 12.6 | 1.26 | KD | - | 18 | -20 | -2 | KUO | 38.3 | 1.5 | 3.0 | 8/0 | 12-27 sprite_jab1 sprite_upper_hook (on hit); super |
| sprite_sweep_charged |  | low | 15 | 4 | 34 | 52 | 12.6 | 1.26 | KD | - | 18 | -20 | - | KUK | 38.3 | 3.0 | 4.0 | 8/0 | 16-31 sprite_jab1 sprite_upper_hook (on hit); super |
| sprite_sweep_charged @full |  | low | 15 +45 held | 4 | 34 | 52 | 22.7 | 2.27 | KD | - | 18 | -20 | - | KUK | 53.5 | 3.0 | 4.0 | 8/0 | 16-31 sprite_jab1 sprite_upper_hook (on hit); super |
| sprite_kick_mid | heavy | mid | 12 | 4 | 27 | 42 | 15.8 | 1.58 | stagger 36 | +5 | 20 | -11 | 0 | OKK | 38.3 | 2.5 | 0.0 | 8/0 | 14-28 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_charge_punch |  | mid | 15 | 4 | 35 | 53 | 11.6 | 1.16 | stun 26 | -13 | 16 | -23 | - | KKK | 34.0 | 13.0 | 4.0 | 8/0 | super |
| sprite_charge_punch @full |  | mid | 15 +45 held | 4 | 35 | 53 | 25.4 | 2.54 | KD | - | 16 | -23 | - | KKK | 47.6 | 13.0 | 4.0 | 8/0 | super |
| sprite_smash_up |  | high | 15 | 4 | 35 | 53 | 11.6 | 1.16 | stun 26 | -13 | 16 | -23 | - | KKU | 34.0 | 1.5 | 9.5 | 8/0 | super |
| sprite_smash_up @full |  | high | 15 +45 held | 4 | 35 | 53 | 25.4 | 2.54 | KD | - | 16 | -23 | - | KKU | 47.6 | 1.5 | 9.5 | 8/0 | super |
| sprite_smash_down |  | low | 15 | 4 | 35 | 53 | 11.6 | 1.16 | stun 26 | -13 | 16 | -23 | - | KUK | 34.0 | 3.0 | -4.0 | 8/0 | super |
| sprite_smash_down @full |  | low | 15 +45 held | 4 | 35 | 53 | 25.4 | 2.54 | KD | - | 16 | -23 | - | KUK | 47.6 | 3.0 | -4.0 | 8/0 | super |
| sprite_smash_left |  | mid | 15 | 4 | 35 | 53 | 11.6 | 1.16 | stun 26 | -13 | 16 | -23 | - | KKK | 34.0 | 3.0 | 2.5 | 8/0 | super |
| sprite_smash_left @full |  | mid | 15 +45 held | 4 | 35 | 53 | 25.4 | 2.54 | KD | - | 16 | -23 | - | KKK | 47.6 | 3.0 | 2.5 | 8/0 | super |
| sprite_smash_right |  | mid | 15 | 4 | 35 | 53 | 11.6 | 1.16 | stun 26 | -13 | 16 | -23 | - | KKK | 34.0 | 3.0 | 2.5 | 8/0 | super |
| sprite_smash_right @full |  | mid | 15 +45 held | 4 | 35 | 53 | 25.4 | 2.54 | KD | - | 16 | -23 | - | KKK | 47.6 | 3.0 | 2.5 | 8/0 | super |
| sprite_charge_kick |  | mid | 17 | 4 | 37 | 57 | 14.7 | 1.47 | stagger 36 | -5 | 20 | -21 | - | KKK | 34.0 | 6.0 | 0.0 | 8/0 | 20-36 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_charge_kick @full |  | mid | 17 +60 held | 4 | 37 | 57 | 29.4 | 2.94 | stagger 80 | +39 | 20 | -21 | - | KKK | 47.6 | 6.0 | 0.0 | 8/0 | 20-36 sprite_jab1 sprite_upper_hook sprite_sweep (on hit); super |
| sprite_jump_kick | jump_attack | mid | 6 | 8 | 8 | 21 | 10.5 | 1.05 | stun 24 | +8 | 12 | -4 | - | PPU | - | 3.0 | 0.0 | 0/0 |  |
| sprite_dive_kick | jump_heavy | mid | 7 | 12 | 10 | 28 | 13.7 | 1.37 | KD | - | 16 | -6 | - | KKU | 38.3 | 4.0 | 3.0 | 8/0 |  |
| sprite_duck_kick | duck_heavy | low | 6 | 4 | 14 | 23 | 11.6 | 1.16 | KD | - | 12 | -6 | -8 | KUO | 38.3 | 1.5 | 2.5 | 8/0 | super |
| sprite_getup_kick | getup_attack | low | 6 | 10 | 16 | 31 | 9.4 | 0.95 | KD | - | 12 | -14 | -8 | KUO | 38.3 | 4.0 | 3.0 | 8/0 |  |
| sprite_dash_punch | dash_attack | mid | 6 | 5 | 14 | 24 | 12.6 | 1.26 | KD | - | 14 | -5 | - | KKK | 38.3 | 6.0 | 3.0 | 8/0 |  |
| sprite_throw | throw | mid | 5 | 3 | 22 | 29 | 18.9 | 1.89 | KD | - | - | - | - | throw | - | 5.5 | 5.0 | 8/0 |  |
| sprite_counter | counter | mid | 3 | 4 | 18 | 24 | 14.7 | 1.47 | KD | - | 16 | -6 | -4 | OKK | 38.3 | 3.0 | 7.0 | 8/0 | super |
| sprite_ki_blast | ki_blast | mid | shot 7 | 0 | 13 | 19 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| sprite_ki_blast_shot | shot of sprite_ki_blast | mid | - | - | - | - | 5.3 | 0.53 | stun 16 | - | 8 | - | - | PPP | - | 2.0 | 0.0 | 3/0 | - |
| sprite_ki_blast_charged |  | mid | shot 9 | 0 | 16 | 24 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| sprite_ki_blast_charged @full |  | mid | shot 9 +30 held | 0 | 16 | 24 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| sprite_ki_blast_charged_shot | shot of sprite_ki_blast_charged | mid | - | - | - | - | 12.6 | 1.26 | KD | - | 14 | - | - | KKK | 38.3 | 6.0 | 4.0 | 8/0 | - |
| sprite_rush | super1 | mid | 7 | 6 | 24 | 36 | 8.4 | 0.84 | stun 40 | chain | 12 | -18 | - | KKK | 85.0 | 0.5 | 0.0 | 3/0 | auto sprite_rush_2 on hit |
| sprite_rush_2 |  | mid | 3 | 2 | 5 | 9 | 7.3 | 0.74 | stun 30 | chain | 12 | +5 | - | KKK | 12.8 | 0.5 | 0.0 | 3/0 | auto sprite_rush_3 on hit |
| sprite_rush_3 |  | mid | 3 | 2 | 5 | 9 | 7.3 | 0.74 | stun 30 | chain | 12 | +5 | - | KKK | 12.8 | 0.5 | 0.0 | 3/0 | auto sprite_rush_4 on hit |
| sprite_rush_4 |  | mid | 3 | 2 | 5 | 9 | 7.3 | 0.74 | stun 30 | chain | 12 | +5 | - | KKK | 12.8 | 0.5 | 0.0 | 3/0 | auto sprite_rush_finish on hit |
| sprite_rush_finish |  | mid | 6 | 3 | 22 | 30 | 25.2 | 2.52 | KD | - | 12 | -13 | - | KKK | 12.8 | 9.0 | 8.0 | 14/0 |  |
| sprite_beam | super2 | mid | shot 15 | 0 | 64 | 78 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| sprite_beam_shot | shot of sprite_beam | mid | - | - | - | - | 3.8 | 0.38 | stun 18 | - | 12 | - | - | KKK | 10.2 | 1.0 | 0.0 | 1/0 | - |
| sprite_ultimate | ultimate | mid | shot 25 | 0 | 96 | 120 | 0.0 | 0.0 | - | - | - | - | - | - | - | 1.5 | 0.0 | 0/0 |  |
| sprite_ultimate_shot | shot of sprite_ultimate | mid | - | - | - | - | 4.6 | 0.46 | stun 18 | - | 14 | - | - | KKK | 21.3 | 1.0 | 0.0 | 1/0 | - |

