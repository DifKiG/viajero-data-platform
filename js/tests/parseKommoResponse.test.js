const parseKommoResponse = require('../sync-engine/parseKommoResponse');

const input = {

    data: JSON.stringify({

        _page: 1,

        _links: {

            next: {

                href: 'https://kommo/page=2'

            }

        },

        _embedded: {

            leads: [

                {
                    id: 1,
                    name: 'Lead 1'
                },

                {
                    id: 2,
                    name: 'Lead 2'
                }

            ]

        }

    })

};

const result = parseKommoResponse(input);

console.log(result);