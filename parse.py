import re, json, os, math

LIBCRAFTS_DIR = os.path.join(os.path.dirname(__file__), 'libcrafts')
AUX_FILE = r'c:\Games\TurtleWoW\WTF\Account\TUTTLES\SavedVariables\aux-addon.lua'

def parse_recipes():
    recipes = {}
    items = {}

    for fname in os.listdir(LIBCRAFTS_DIR):
        if not fname.endswith('.lua'):
            continue
        profession = fname.replace('.lua', '')
        filepath = os.path.join(LIBCRAFTS_DIR, fname)
        with open(filepath, 'r', encoding='utf-8') as f:
            text = f.read()

        # Parse each NewCraft block
        craft_re = re.compile(
            r'module:NewCraft\((\d+),\s*"([^"]+)",\s*(\d+)',
            re.MULTILINE
        )
        result_re = re.compile(r':SetResult\((\d+)\)')
        reagent_re = re.compile(r':AddReagent\((\d+),\s*(\d+)\)\s*--\s*(.+)')

        blocks = text.split('module:NewCraft(')
        for block in blocks[1:]:
            block = 'module:NewCraft(' + block
            m = craft_re.search(block)
            if not m:
                continue
            spell_id = int(m.group(1))
            craft_name = m.group(2)
            skill_req = int(m.group(3))

            rm = result_re.search(block)
            result_id = int(rm.group(1)) if rm else None

            reagents = []
            for rmatch in reagent_re.finditer(block):
                reagent_id = int(rmatch.group(1))
                qty = int(rmatch.group(2))
                reagent_name = rmatch.group(3).strip()
                reagents.append({
                    'itemId': reagent_id,
                    'name': reagent_name,
                    'qty': qty
                })
                items[reagent_id] = reagent_name

            if result_id:
                items[result_id] = craft_name

            recipe_key = str(result_id or spell_id)
            recipes.setdefault(profession, []).append({
                'spellId': spell_id,
                'name': craft_name,
                'skillReq': skill_req,
                'resultId': result_id,
                'reagents': reagents
            })

    return recipes, items


def parse_aux_prices(aux_path):
    with open(aux_path, 'r', encoding='utf-8') as f:
        text = f.read()

    factions = {}

    # Find all faction history blocks
    faction_re = re.compile(r'\["([^"]+)\|([^"]+)"\]\s*=\s*\{')
    history_start = re.compile(r'\["history"\]\s*=\s*\{')

    # Find faction sections
    faction_section = text.find('["faction"]')
    if faction_section == -1:
        return factions

    pos = faction_section
    while True:
        fm = faction_re.search(text, pos)
        if not fm or fm.start() > text.find('["realm"]', faction_section):
            break

        realm = fm.group(1)
        faction_name = fm.group(2)
        key = f"{realm}|{faction_name}"

        # Find history block within this faction
        hm = history_start.search(text, fm.end())
        if not hm:
            pos = fm.end()
            continue

        # Parse history entries until closing brace
        h_start = hm.end()
        brace_depth = 1
        h_end = h_start
        for i in range(h_start, len(text)):
            if text[i] == '{':
                brace_depth += 1
            elif text[i] == '}':
                brace_depth -= 1
                if brace_depth == 0:
                    h_end = i
                    break

        history_text = text[h_start:h_end]
        entry_re = re.compile(r'\["(\d+):(\d+)"\]\s*=\s*"([^"]*)"')

        prices = {}
        for em in entry_re.finditer(history_text):
            item_id = int(em.group(1))
            suffix_id = int(em.group(2))
            data_str = em.group(3)

            parts = data_str.split('#')
            if len(parts) < 2:
                continue

            daily_min = None
            if parts[1]:
                try:
                    daily_min = int(float(parts[1]))
                except ValueError:
                    pass

            # Parse historical data points for weighted median
            data_points = []
            if len(parts) > 2 and parts[2]:
                for dp in parts[2].split(';'):
                    dp_parts = dp.split('@')
                    if len(dp_parts) == 2:
                        try:
                            data_points.append({
                                'value': int(float(dp_parts[0])),
                                'time': int(dp_parts[1])
                            })
                        except ValueError:
                            pass

            # Compute weighted median (same algorithm as aux)
            market_value = daily_min
            if data_points:
                total_weight = 0
                weighted = []
                ref_time = data_points[0]['time']
                for dp in data_points:
                    weight = 0.99 ** round((ref_time - dp['time']) / 86400)
                    total_weight += weight
                    weighted.append({'value': dp['value'], 'weight': weight})
                if total_weight > 0:
                    for w in weighted:
                        w['weight'] /= total_weight
                    weighted.sort(key=lambda x: x['value'])
                    cum = 0
                    median_value = weighted[-1]['value']
                    for w in weighted:
                        cum += w['weight']
                        if cum >= 0.5:
                            median_value = w['value']
                            break
                    if market_value is None:
                        market_value = median_value

            if suffix_id == 0 and market_value is not None:
                prices[item_id] = {
                    'minBuyout': daily_min,
                    'marketValue': market_value
                }

        factions[key] = prices
        pos = h_end

    return factions


if __name__ == '__main__':
    recipes, items = parse_recipes()

    recipes_out = {'items': {}, 'professions': {}}
    for item_id, item_name in items.items():
        recipes_out['items'][str(item_id)] = {'name': item_name}

    for prof, craft_list in recipes.items():
        recipes_out['professions'][prof] = {
            'name': prof,
            'recipes': []
        }
        for craft in craft_list:
            recipes_out['professions'][prof]['recipes'].append({
                'spellId': craft['spellId'],
                'name': craft['name'],
                'skillReq': craft['skillReq'],
                'resultId': craft['resultId'],
                'reagents': [{'itemId': r['itemId'], 'qty': r['qty']} for r in craft['reagents']]
            })

    with open('recipes.json', 'w', encoding='utf-8') as f:
        json.dump(recipes_out, f, indent=2)
    print(f"recipes.json: {len(items)} items, {sum(len(v['recipes']) for v in recipes_out['professions'].values())} recipes across {len(recipes_out['professions'])} professions")

    if os.path.exists(AUX_FILE):
        factions = parse_aux_prices(AUX_FILE)
        with open('prices.json', 'w', encoding='utf-8') as f:
            json.dump(factions, f, indent=2)
        for fk, prices in factions.items():
            print(f"prices.json: {fk} = {len(prices)} items with prices")
    else:
        print(f"aux file not found: {AUX_FILE}")
